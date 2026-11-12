import AppKit

let application = NSApplication.shared
application.setActivationPolicy(.regular)
let previousApp = NSWorkspace.shared.frontmostApplication
TextEditingCommands.install(in: application)
var checks = 0
func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    precondition(value(), message)
}

// Spy проверяет маршрутизацию копирования/вставки без доступа к общему буферу.
final class Editor: NSTextView {
    var commands: [String] = []
    override func copy(_ sender: Any?) { commands.append("copy") }
    override func paste(_ sender: Any?) { commands.append("paste") }
    override func cut(_ sender: Any?) { commands.append("cut") }
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if [#selector(copy(_:)), #selector(paste(_:)), #selector(cut(_:))].contains(item.action) { return true }
        return super.validateUserInterfaceItem(item)
    }
}
final class EditorDelegate: NSObject, NSWindowDelegate {
    let editor = Editor()
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        guard !(client is NSSecureTextField) else { return nil }
        editor.isFieldEditor = true
        editor.isEditable = true
        editor.isSelectable = true
        return editor
    }
}
func runChecks() {
    let window = NSWindow(contentRect: NSRect(x: 200, y: 300, width: 600, height: 350),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "Проверка команд Runvoice"
    window.center()
    let delegate = EditorDelegate()
    window.delegate = delegate
    window.makeKeyAndOrderFront(nil)
    application.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    defer {
        window.close()
        if let previousApp { previousApp.activate(options: []) }
    }
    func event(_ key: String, code: UInt16, flags: NSEvent.ModifierFlags = .command) -> NSEvent {
        let characters = flags.contains(.shift) ? key.uppercased() : key
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, characters: characters,
                               charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }
    func key(_ key: String, code: UInt16, flags: NSEvent.ModifierFlags = .command) -> Bool {
        let handled = application.mainMenu!.performKeyEquivalent(with: event(key, code: code, flags: flags))
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        return handled
    }
    func checkEditor(_ editor: Editor, name: String) {
        editor.string = "Тест Cypress Playwright"
        editor.isEditable = true
        editor.isSelectable = true
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        expect(key("a", code: 0), "\(name): ⌘A обработано меню")
        if editor.selectedRange().length != editor.string.utf16.count {
            let target = application.target(forAction: #selector(NSText.selectAll(_:)), to: nil, from: nil)
            let info = "debug keyWindow=\(String(describing: application.keyWindow)) first=\(String(describing: window.firstResponder)) target=\(String(describing: target)) range=\(editor.selectedRange()) text=\(editor.string) active=\(application.isActive) visible=\(window.isVisible) canKey=\(window.canBecomeKey) policy=\(application.activationPolicy())\n"
            FileHandle.standardError.write(Data(info.utf8))
        }
        expect(editor.selectedRange().length == editor.string.utf16.count, "\(name): выделен весь текст")
        expect(key("c", code: 8) && editor.commands.last == "copy", "\(name): ⌘C дошло до редактора")
        expect(key("v", code: 9) && editor.commands.last == "paste", "\(name): ⌘V дошло до редактора")
        expect(key("x", code: 7) && editor.commands.last == "cut", "\(name): ⌘X дошло до редактора")
        let before = editor.commands.count
        expect(!key("c", code: 8, flags: .control), "\(name): Ctrl+C не переназначен")
        expect(editor.commands.count == before, "\(name): Ctrl не вызывает команды ⌘")
    }

    let prompt = Editor(frame: NSRect(x: 10, y: 100, width: 500, height: 180))
    window.contentView!.addSubview(prompt)
    window.makeFirstResponder(prompt)
    checkEditor(prompt, name: "NSTextView / промпт")
    prompt.allowsUndo = true
    prompt.string = ""
    prompt.insertText("Undo", replacementRange: NSRange(location: 0, length: 0))
    expect(key("z", code: 6) && prompt.string.isEmpty, "NSTextView: ⌘Z отменяет ввод")
    let couldRedo = prompt.undoManager?.canRedo
    let redoHandled = key("z", code: 6, flags: [.command, .shift])
    if !redoHandled || prompt.string != "Undo" {
        FileHandle.standardError.write(Data("redo handled=\(redoHandled) text=\(prompt.string) canRedoBefore=\(String(describing: couldRedo)) canRedoAfter=\(String(describing: prompt.undoManager?.canRedo)) target=\(String(describing: application.target(forAction: Selector(("redo:")), to: nil, from: nil)))\n".utf8))
    }
    expect(redoHandled && prompt.string == "Undo", "NSTextView: ⇧⌘Z повторяет ввод")
    let field = NSTextField(frame: NSRect(x: 10, y: 55, width: 500, height: 24))
    field.stringValue = "Cypress"
    window.contentView!.addSubview(field)
    field.selectText(nil)
    expect(window.firstResponder === delegate.editor, "NSTextField использует field editor")
    checkEditor(delegate.editor, name: "NSTextField / словарь и провайдер")
    let secure = NSSecureTextField(frame: NSRect(x: 10, y: 15, width: 500, height: 24))
    secure.stringValue = "dummy-test-key"
    window.contentView!.addSubview(secure)
    secure.selectText(nil)
    let secureEditor = window.firstResponder as! NSTextView
    expect(key("a", code: 0), "Secure field: ⌘A работает")
    expect(secureEditor.selectedRange().length == secure.stringValue.utf16.count, "Secure field: весь ключ выделен")

    let controls = RecognitionPreviewControls()
    expect(controls.options == RecognitionPreview(), "Настройки preview по умолчанию: включён, 3 строки")
    expect(controls.isLineCountEnabled, "Поле строк доступно при включённом preview")
    let previewCheck = controls.arrangedSubviews[0] as! NSButton
    previewCheck.performClick(nil)
    expect(!controls.options.enabled && !controls.isLineCountEnabled, "Флажок отключает поле и stepper")
    previewCheck.performClick(nil)
    expect(controls.options.enabled && controls.isLineCountEnabled, "Флажок снова включает поле и stepper")
    controls.options = RecognitionPreview(enabled: false, lineCount: 8)
    expect(!controls.isLineCountEnabled && controls.options.lineCount == 8, "Отключение блокирует поле, сохраняя значение")
    controls.options = RecognitionPreview(enabled: true, lineCount: 8)
    expect(controls.isLineCountEnabled && controls.options.lineCount == 8, "Включение возвращает доступ к числу строк")
    let spinner = HUDSpinnerView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
    spinner.startAnimation(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    expect(spinner.isAnimating && spinner.phase != 0, "Спиннер меняет фазу во время обработки")
    spinner.stopAnimation(nil)
    let stoppedPhase = spinner.phase
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    expect(!spinner.isAnimating && spinner.phase == stoppedPhase, "После завершения таймер спиннера остановлен")
    spinner.startAnimation(nil)
    expect(spinner.isAnimating && spinner.phase == 0, "Новая обработка запускает спиннер заново")
    spinner.stopAnimation(nil)

    let dictionary = SpeechVocabularyEditor(frame: window.contentView!.bounds)
    window.contentView!.addSubview(dictionary)
    dictionary.load(["Cypress", "Playwright"])
    dictionary.layoutSubtreeIfNeeded()
    expect(!dictionary.hasChanges && dictionary.table.numberOfRows == 2, "Словарь загружается списком без ложных изменений")
    dictionary.input.string = " cypress, GitHub Actions\nRedis\r\n"
    expect(dictionary.hasChanges, "Неотправленный список учитывается при закрытии окна")
    expect(dictionary.commit() && dictionary.terms == ["Cypress", "Playwright", "GitHub Actions", "Redis"],
           "Сохранение добавляет черновик списка, сохраняя фразы и порядок")
    dictionary.input.string = String(repeating: "я", count: 81)
    let beforeInvalid = dictionary.terms
    expect(!dictionary.commit() && dictionary.terms == beforeInvalid && dictionary.input.string.count == 81,
           "Ошибка длины не обрезает словарь и оставляет ввод для исправления")
    expect(!dictionary.validationMessage.isEmpty, "Ошибка показана рядом со словарём")
    dictionary.input.string = (0..<65).map { "term\($0)" }.joined(separator: ",")
    expect(!dictionary.commit() && dictionary.terms == beforeInvalid && !dictionary.input.string.isEmpty,
           "Переполнение отклоняется целиком, текст остаётся в поле")
    dictionary.input.string = ""
    dictionary.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
    dictionary.removeSelected()
    expect(dictionary.terms == ["Cypress", "GitHub Actions", "Redis"], "Удаление выбранной строки сохраняет остальные")
    let cell = dictionary.table.view(atColumn: 0, row: 0, makeIfNecessary: true) as! NSTableCellView
    cell.textField!.selectText(nil)
    let termEditor = cell.textField!.currentEditor() as! NSTextView
    termEditor.setSelectedRange(NSRange(location: 0, length: termEditor.string.utf16.count))
    termEditor.insertText("Cypress Cloud", replacementRange: termEditor.selectedRange())
    expect(dictionary.hasChanges, "Активное редактирование строки учитывается до потери фокуса")
    expect(dictionary.commit() && dictionary.terms.first == "Cypress Cloud", "Save завершает редактирование строки без потери текста")
    let activeCell = dictionary.table.view(atColumn: 0, row: 0, makeIfNecessary: true) as! NSTableCellView
    activeCell.textField!.selectText(nil)
    let activeEditor = activeCell.textField!.currentEditor() as! NSTextView
    activeEditor.setSelectedRange(NSRange(location: 0, length: activeEditor.string.utf16.count))
    activeEditor.insertText("Несохранённое изменение", replacementRange: activeEditor.selectedRange())
    dictionary.load(["Cypress"])
    expect(dictionary.terms == ["Cypress"] && !dictionary.hasChanges,
           "Загрузка сохранённого списка завершает старый field editor до обновления строк")
    dictionary.reset()
    expect(dictionary.terms.isEmpty && dictionary.hasChanges, "Сброс словаря — несохранённое изменение")
    dictionary.load(["Cypress"])
    expect(!dictionary.hasChanges, "Повторное открытие восстанавливает сохранённое значение")
    dictionary.removeFromSuperview()

    let screen = NSScreen.main!.visibleFrame
    let anchor = NSRect(x: screen.maxX - 50, y: screen.maxY, width: 22, height: 24)
    let hintLayout = StatusHintLayout(width: 280, anchor: anchor, visibleFrame: screen)
    expect(hintLayout.frame.minX >= screen.minX + 8 && hintLayout.frame.maxX <= screen.maxX - 8,
           "Хинт ограничен экраном у правого края")
    expect(hintLayout.frame.minX + hintLayout.arrowX == anchor.midX && hintLayout.frame.maxY == anchor.minY - 4,
           "Хвост хинта указывает на кнопку строки меню")
    let hint = StatusHintController()
    let focusedWindow = application.keyWindow
    hint.show(shortcut: "⌃⌥D", anchor: anchor, visibleFrame: screen)
    expect(hint.isVisible && hint.text == "Для диктовки нажмите ⌃⌥D", "Хинт содержит настроенный хоткей")
    expect(application.keyWindow === focusedWindow, "Хинт не забирает фокус")
    hint.update(shortcut: "⌥Space")
    expect(hint.text.hasSuffix("⌥Space"), "Сохранение хоткея обновляет видимый хинт")
    let hintPanel = application.windows.first { $0.identifier?.rawValue == "startup-hint" }!
    let click = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: [],
                                  timestamp: 0, windowNumber: hintPanel.windowNumber, context: nil,
                                  eventNumber: 0, clickCount: 1, pressure: 1)!
    hintPanel.contentView!.mouseDown(with: click)
    RunLoop.main.run(until: Date().addingTimeInterval(0.25))
    expect(!hint.isVisible && application.keyWindow === focusedWindow, "Клик закрывает хинт затуханием без смены фокуса")
    hint.show(shortcut: "⌥Space", anchor: anchor, visibleFrame: screen)
    RunLoop.main.run(until: Date().addingTimeInterval(4.3))
    expect(!hint.isVisible, "Хинт автоматически скрывается через 4 секунды")
    print("OK: \(checks) проверок нативных команд macOS, preview, словаря и хинта")

}

// Из timer callback вложенный RunLoop обслуживает и завершения AppKit-анимаций;
// ожидание внутри блока main queue блокировало бы их искусственно.
let startTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
    runChecks()
    application.terminate(nil)
}
application.run()
