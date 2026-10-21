import AppKit
import ApplicationServices

/// Захват и замена выделенного текста в активном приложении.
enum SelectionService {
    enum CaptureError: LocalizedError {
        case noAccessibility
        case noSelection
        case secureField
        case copyFailed

        var errorDescription: String? {
            switch self {
            case .noAccessibility: return "Нет доступа Accessibility"
            case .noSelection: return "Нет выделенного текста"
            case .secureField: return "Защищённое поле нельзя изменить"
            case .copyFailed: return "Не удалось прочитать выделение"
            }
        }
    }

    enum ReplaceResult {
        case replaced
        case pasted
        case copied
    }

    struct Context {
        enum Source: Equatable {
            case accessibility
            case clipboard
        }

        let text: String
        let pid: pid_t
        let element: AXUIElement?
        let range: CFRange?
        let source: Source
    }

    static func capture() -> Result<Context, Error> {
        guard AXIsProcessTrusted() else {
            Log.write("selection: нет Accessibility")
            return .failure(CaptureError.noAccessibility)
        }

        if !ProcessInfo.processInfo.arguments.contains("--force-improve-clipboard"),
           let element = focusedElement() {
            if let subrole = stringAttribute(element, kAXSubroleAttribute as String),
               subrole == (kAXSecureTextFieldSubrole as String) {
                return .failure(CaptureError.secureField)
            }

            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            let range = selectedRange(element)
            let role = stringAttribute(element, kAXRoleAttribute as String) ?? "?"
            let selected = stringAttribute(element, kAXSelectedTextAttribute as String)
            Log.write("selection: pid=\(pid) role=\(role) selected=\(selected?.count ?? -1) range=\(String(describing: range))")

            if let text = selected, !text.isEmpty {
                return .success(Context(text: text, pid: pid, element: element,
                                        range: range, source: .accessibility))
            }

            // Приложение не отдаёт AXSelectedText. Если выделения точно нет — не копируем.
            if let range, range.length == 0 {
                Log.write("selection: пустой диапазон — нет выделения")
                return .failure(CaptureError.noSelection)
            }

            guard let text = copySelectionViaClipboard(), !text.isEmpty else {
                Log.write("selection: копирование через буфер не дало текста")
                return .failure(CaptureError.copyFailed)
            }
            Log.write("selection: clipboard \(text.count) символов")
            return .success(Context(text: text, pid: pid, element: element,
                                    range: range, source: .clipboard))
        }

        // Electron/VS Code и подобные приложения могут не отдавать focused element.
        // В этом случае читаем выделение через ⌘C и потом вставляем через ⌘V.
        guard let front = NSWorkspace.shared.frontmostApplication else {
            Log.write("selection: нет frontmost application")
            return .failure(CaptureError.noSelection)
        }
        Log.write("selection: fallback front=\(front.localizedName ?? "?") pid=\(front.processIdentifier)")
        guard let text = copySelectionViaClipboard(), !text.isEmpty else {
            Log.write("selection: fallback-копирование не дало текста")
            return .failure(CaptureError.noSelection)
        }
        Log.write("selection: fallback clipboard pid=\(front.processIdentifier) \(text.count) символов")
        return .success(Context(text: text, pid: front.processIdentifier, element: nil,
                                range: nil, source: .clipboard))
    }

    static func replace(_ context: Context, with text: String) -> ReplaceResult {
        guard isStillValid(context) else {
            copyToClipboard(text)
            return .copied
        }

        if let element = context.element {
            if AXUIElementSetAttributeValue(element,
                                            kAXSelectedTextAttribute as CFString,
                                            text as CFString) == .success {
                return .replaced
            }
            Log.write("improve: AXSelectedText не поддерживается")
        } else {
            Log.write("improve: AX недоступен — вставляю через буфер")
        }

        guard isStillValid(context) else {
            Log.write("improve: выделение изменилось — копирую")
            copyToClipboard(text)
            return .copied
        }

        let pasteboard = NSPasteboard.general
        let saved = savePasteboard()
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        postPaste(to: nil)
        // Даём runloop'у доставить ⌘V и приложению — обработать вставку.
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if SettingsStore.load().restoreClipboard {
            restorePasteboard(saved)
        }
        return .pasted
    }

    // MARK: - Accessibility

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(system,
                                                  kAXFocusedUIElementAttribute as CFString,
                                                  &value)
        guard error == .success, let value else {
            let front = NSWorkspace.shared.frontmostApplication
            Log.write("selection: focused error=\(error.rawValue) front=\(front?.localizedName ?? "?")")
            return nil
        }
        return (value as! AXUIElement)
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value else { return nil }
        return value as? String
    }

    private static func selectedRange(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,
                                            kAXSelectedTextRangeAttribute as CFString,
                                            &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        var range = CFRange()
        guard AXValueGetType(axValue) == .cfRange,
              AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    private static func isStillValid(_ context: Context) -> Bool {
        if context.element == nil {
            guard let front = NSWorkspace.shared.frontmostApplication,
                  front.processIdentifier == context.pid else {
                Log.write("improve: valid fallback — другое приложение")
                return false
            }
            guard let current = copySelectionViaClipboard(), current == context.text else {
                Log.write("improve: valid fallback — выделение изменилось")
                return false
            }
            return true
        }

        guard let element = context.element else { return false }
        guard let focused = focusedElement() else {
            Log.write("improve: valid=false — нет focused element")
            return false
        }
        var pid: pid_t = 0
        AXUIElementGetPid(focused, &pid)
        let same = CFEqual(focused, element)
        let currentText = stringAttribute(focused, kAXSelectedTextAttribute as String)
        let currentRange = selectedRange(focused)
        Log.write("improve: valid pid=\(pid) same=\(same) text=\(currentText?.count ?? -1) range=\(String(describing: currentRange))")
        guard pid == context.pid, same else { return false }

        if let current = currentText, current != context.text {
            return false
        }
        if let saved = context.range,
           let current = currentRange,
           current.location != saved.location || current.length != saved.length {
            return false
        }

        // Некоторые Web/Electron-поля отдают элемент, но не текст и не диапазон.
        // Тогда проверяем выделение тем же ⌘C, которым его читали.
        if context.source == .clipboard, currentText == nil, currentRange == nil {
            guard let current = copySelectionViaClipboard(), current == context.text else {
                Log.write("improve: valid clipboard — выделение изменилось")
                return false
            }
        }
        return true
    }

    // MARK: - Clipboard fallback

    private static func copySelectionViaClipboard() -> String? {
        let pasteboard = NSPasteboard.general
        let saved = savePasteboard()
        pasteboard.clearContents()
        let before = pasteboard.changeCount
        postCommandC(to: NSWorkspace.shared.frontmostApplication?.processIdentifier)

        // TextEdit/Electron могут обрабатывать ⌘C асинхронно: ждём изменения pasteboard,
        // иначе восстанавливаем буфер раньше, чем приложение успеет скопировать.
        var text: String?
        for _ in 0..<48 {
            usleep(25_000)
            if pasteboard.changeCount != before {
                text = pasteboard.string(forType: .string)
                if text != nil { break }
            }
        }
        if text == nil {
            text = pasteboard.string(forType: .string)
        }
        Log.write("selection: copy change=\(pasteboard.changeCount - before) text=\(text?.count ?? -1)")
        restorePasteboard(saved)
        return text
    }

    private static func savePasteboard() -> [[NSPasteboard.PasteboardType: Data]] {
        let pasteboard = NSPasteboard.general
        return (pasteboard.pasteboardItems ?? []).map { item in
            var values: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    values[type] = data
                }
            }
            return values
        }
    }

    private static func restorePasteboard(_ saved: [[NSPasteboard.PasteboardType: Data]]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let items: [NSPasteboardItem] = saved.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values {
                item.setData(data, forType: type)
            }
            return item
        }
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }

    private static func postCommandC(to pid: pid_t?) { postKey(8, to: pid) }
    private static func postPaste(to pid: pid_t?) { postKey(9, to: pid) }

    private static func postKey(_ code: CGKeyCode, to pid: pid_t?) {
        guard AXIsProcessTrusted() else {
            Log.write("selection: нет Accessibility для отправки клавиши")
            return
        }
        let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        if let pid {
            down?.postToPid(pid)
            usleep(30_000)
            up?.postToPid(pid)
        } else {
            down?.post(tap: .cghidEventTap)
            usleep(30_000)
            up?.post(tap: .cghidEventTap)
        }
    }

    private static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
