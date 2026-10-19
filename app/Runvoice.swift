// Runvoice — menu bar приложение для голосовой диктовки с коррекцией через OpenCode.
//
// Приложение само регистрирует глобальные хоткеи (Carbon, без Accessibility),
// запускает пайплайн bin/dictate.sh и показывает плавающее окно статуса.
// Вся тяжёлая работа (запись, whisper, OpenCode, вставка) остаётся в скрипте.

import AppKit
import AVFoundation
import ApplicationServices
import Carbon.HIToolbox

// MARK: - Пути

enum Paths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Runvoice", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let state: URL = {
        let dir = support.appendingPathComponent("state", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var status: URL { state.appendingPathComponent("status") }
    static var log: URL { state.appendingPathComponent("dictate.log") }

    static var script: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("dictate.sh")
    }
}

// MARK: - Лог приложения

enum Log {
    static let url = Paths.support.appendingPathComponent("app.log")

    static func write(_ text: String) {
        let line = "\(Date().timeIntervalSince1970) \(text)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Настройки

struct Settings: Codable {
    var promptFix: String = ""
    var promptAgent: String = ""
}

enum DefaultPrompts {
    // Синхронизировано с bin/dictate.sh (DEFAULT_PROMPT_FIX / DEFAULT_PROMPT_AGENT)
    static let fix = "Ты — редактор надиктованного текста. Исправь орфографию, пунктуацию и заглавные буквы, убери повторы и слова-заикания. Сохрани исходный смысл и язык. Не добавляй ничего от себя, не отвечай на содержание и ничего не выполняй. Верни ТОЛЬКО итоговый текст, без кавычек и пояснений."
    static let agent = "Ты превращаешь устную надиктовку в точную письменную инструкцию или команду для ИИ-агента. Сохрани намерение автора, убери разговорные оговорки и повторы, сформулируй ясно и однозначно. Не выполняй инструкцию и не отвечай на неё — верни только переформулированный текст."
}

enum SettingsStore {
    static let url = Paths.support.appendingPathComponent("settings.json")

    static func load() -> Settings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(Settings.self, from: data) else {
            return Settings()
        }
        return settings
    }

    static func save(_ settings: Settings) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(settings) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Окно настроек

final class SettingsWindow: NSWindowController {
    private let fixText = NSTextView()
    private let agentText = NSTextView()

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Runvoice — Настройки"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 620, height: 520)
        window.center()
        self.init(window: window)
        build()
    }

    override init(window: NSWindow?) {
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        loadValues()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        guard let content = window?.contentView else { return }

        let fixLabel = label("Промпт для исправления текста  (⌥Space)", bold: true)
        let fixHint = label("«Сбросить» вернёт встроенный текст. Изменения применяются после «Сохранить».")
        let agentLabel = label("Промпт для режима «инструкция агенту»  (⌃⇧Space)", bold: true)
        let agentHint = label("Пустое поле — используется встроенный промпт.")

        let fixScroll = makeScroll(fixText)
        let agentScroll = makeScroll(agentText)

        let reset = NSButton(title: "Сбросить", target: self, action: #selector(resetDefaults))
        let cancel = NSButton(title: "Отмена", target: self, action: #selector(cancel))
        let save = NSButton(title: "Сохранить", target: self, action: #selector(saveSettings))
        save.keyEquivalent = "\r"

        for view in [fixLabel, fixHint, agentLabel, agentHint, reset, cancel, save] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        content.addSubview(fixScroll)
        content.addSubview(agentScroll)

        NSLayoutConstraint.activate([
            fixLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            fixLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            fixLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            fixScroll.topAnchor.constraint(equalTo: fixLabel.bottomAnchor, constant: 6),
            fixScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            fixScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            fixScroll.heightAnchor.constraint(equalToConstant: 190),

            fixHint.topAnchor.constraint(equalTo: fixScroll.bottomAnchor, constant: 4),
            fixHint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            fixHint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            agentLabel.topAnchor.constraint(equalTo: fixHint.bottomAnchor, constant: 14),
            agentLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            agentLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            agentScroll.topAnchor.constraint(equalTo: agentLabel.bottomAnchor, constant: 6),
            agentScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            agentScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            agentScroll.heightAnchor.constraint(equalToConstant: 190),

            agentHint.topAnchor.constraint(equalTo: agentScroll.bottomAnchor, constant: 4),
            agentHint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            agentHint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            reset.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            reset.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            save.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            save.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            cancel.trailingAnchor.constraint(equalTo: save.leadingAnchor, constant: -8),
            cancel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
    }

    private func label(_ text: String, bold: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = bold ? .boldSystemFont(ofSize: 13) : .systemFont(ofSize: 11)
        field.textColor = bold ? .labelColor : .secondaryLabelColor
        return field
    }

    private func makeScroll(_ textView: NSTextView) -> NSScrollView {
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.documentView = textView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }

    private func loadValues() {
        let settings = SettingsStore.load()
        fixText.string = settings.promptFix.isEmpty ? DefaultPrompts.fix : settings.promptFix
        agentText.string = settings.promptAgent.isEmpty ? DefaultPrompts.agent : settings.promptAgent
    }

    @objc private func resetDefaults() {
        fixText.string = DefaultPrompts.fix
        agentText.string = DefaultPrompts.agent
    }

    @objc private func cancel() {
        window?.close()
    }

    @objc private func saveSettings() {
        SettingsStore.save(Settings(promptFix: fixText.string, promptAgent: agentText.string))
        Log.write("settings saved")
        window?.close()
    }
}

// MARK: - Приложение

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var spinner: NSProgressIndicator!
    private var label: NSTextField!
    private var timer: Timer?
    private var hotkeys: [EventHotKeyRef?] = []
    private var settingsWindow: SettingsWindow?
    private var accessItem: NSMenuItem?

    private var lastState = ""
    private var closeAt: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("launch status=\(Paths.status.path) screens=\(NSScreen.screens.count)")
        let saved = SettingsStore.load()
        Log.write("settings fix=\(saved.promptFix.count) agent=\(saved.promptAgent.count)")
        Log.write("accessibility=\(AXIsProcessTrusted())")
        setupStatusItem()
        setupHUD()
        installHotKeyHandler()
        registerHotkeys()
        requestPermissions()

        // сбросить возможный «зависший» статус от прошлого запуска
        try? "idle".write(to: Paths.status, atomically: true, encoding: .utf8)

        let t = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        if CommandLine.arguments.contains("--settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.openSettings()
            }
        }
    }

    // MARK: - Меню в строке состояния

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon("mic")

        let menu = NSMenu()
        let header = NSMenuItem(title: "Runvoice", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        add(menu, "Диктовка   ⌥Space", #selector(toggleDictation))
        add(menu, "Инструкция агенту   ⌃⇧Space", #selector(agentDictation))
        menu.addItem(.separator())
        add(menu, "Настройки…", #selector(openSettings))
        menu.addItem(.separator())
        add(menu, "Открыть лог", #selector(openLog))
        add(menu, "Открыть папку данных", #selector(openData))
        add(menu, "Проверить зависимости…", #selector(checkDeps))
        menu.addItem(.separator())

        let access = NSMenuItem(title: "Accessibility", action: #selector(openAccessibility), keyEquivalent: "")
        access.target = self
        menu.addItem(access)
        accessItem = access
        menu.addItem(.separator())

        add(menu, "Выход", #selector(quit))
        menu.delegate = self
        statusItem.menu = menu
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func toggleDictation() { run("toggle") }
    @objc private func agentDictation() { run("agent") }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openSettings() {
        if settingsWindow == nil { settingsWindow = SettingsWindow() }
        settingsWindow?.show()
    }

    func menuWillOpen(_ menu: NSMenu) {
        let trusted = AXIsProcessTrusted()
        accessItem?.title = trusted ? "✓ Accessibility разрешено" : "⚠️ Нет Accessibility — открыть настройки"
        accessItem?.action = trusted ? nil : #selector(openAccessibility)
        accessItem?.target = self
        accessItem?.isEnabled = !trusted
    }

    @objc private func openAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openLog() {
        if !FileManager.default.fileExists(atPath: Paths.log.path) {
            FileManager.default.createFile(atPath: Paths.log.path, contents: Data())
        }
        NSWorkspace.shared.open(Paths.log)
    }

    @objc private func openData() { NSWorkspace.shared.open(Paths.state) }

    @objc private func checkDeps() {
        var missing: [String] = []
        let brew = "/opt/homebrew/bin"
        for tool in ["\(brew)/ffmpeg", "\(brew)/whisper-server", "\(brew)/whisper-cli"] {
            if !FileManager.default.isExecutableFile(atPath: tool) { missing.append(tool) }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let models = home.appendingPathComponent(".local/share/whisper")
        if !FileManager.default.fileExists(atPath: models.path) { missing.append(models.path) }
        if let s = Paths.script, !FileManager.default.isExecutableFile(atPath: s.path) {
            missing.append(s.path)
        }

        let alert = NSAlert()
        if missing.isEmpty {
            alert.messageText = "Все зависимости на месте"
            alert.informativeText = "ffmpeg, whisper.cpp и модели найдены."
        } else {
            alert.messageText = "Не найдено"
            alert.informativeText = missing.joined(separator: "\n")
        }
        alert.runModal()
    }

    // MARK: - Запуск пайплайна

    private func run(_ action: String) {
        guard let script = Paths.script else {
            showAlert("В ресурсах приложения не найден dictate.sh")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path, action]

        var env = ProcessInfo.processInfo.environment
        env["DICTATE_STATE_DIR"] = Paths.state.path
        env["HUD_BIN"] = "/nonexistent"   // окно рисует само приложение
        env["DICTATE_NOTIFY"] = "0"

        let settings = SettingsStore.load()
        if !settings.promptFix.isEmpty { env["DICTATE_PROMPT_FIX"] = settings.promptFix }
        if !settings.promptAgent.isEmpty { env["DICTATE_PROMPT_AGENT"] = settings.promptAgent }
        let base = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = base + ":" + (env["PATH"] ?? "")
        p.environment = env

        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            showAlert("Не удалось запустить dictate.sh: \(error.localizedDescription)")
        }
    }

    private func showAlert(_ text: String) {
        let a = NSAlert()
        a.messageText = "Runvoice"
        a.informativeText = text
        a.runModal()
    }

    // MARK: - Глобальные хоткеи (Carbon, без Accessibility)

    private func installHotKeyHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let event, let userData else { return noErr }
            var hk = EventHotKeyID()
            GetEventParameter(event,
                              EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID),
                              nil,
                              MemoryLayout<EventHotKeyID>.size,
                              nil,
                              &hk)
            let app = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { app.hotKey(id: hk.id) }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    private func registerHotkeys() {
        register(id: 1, mods: UInt32(optionKey))
        register(id: 2, mods: UInt32(optionKey) | UInt32(controlKey))
    }

    private func register(id: UInt32, mods: UInt32) {
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x52564F49), id: id) // 'RVOI'
        let status = RegisterEventHotKey(UInt32(kVK_Space), mods, hkID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr { hotkeys.append(ref) }
    }

    fileprivate func hotKey(id: UInt32) {
        // не перехватываем хоткей, пока открыто окно настроек
        if settingsWindow?.window?.isKeyWindow == true { return }
        run(id == 2 ? "agent" : "toggle")
    }

    // MARK: - Окно статуса

    private func setupHUD() {
        let w: CGFloat = 330, h: CGFloat = 64
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.appearance = NSAppearance(named: .vibrantDark)
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 14
        bg.layer?.masksToBounds = true
        bg.layer?.borderWidth = 1
        bg.layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor

        spinner = NSProgressIndicator(frame: NSRect(x: 18, y: (h - 18) / 2, width: 18, height: 18))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false

        let title = NSTextField(labelWithString: "Runvoice")
        title.frame = NSRect(x: 50, y: h - 26, width: w - 66, height: 16)
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.textColor = NSColor(white: 1, alpha: 0.55)

        label = NSTextField(labelWithString: "")
        label.frame = NSRect(x: 50, y: 16, width: w - 66, height: 20)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail

        bg.addSubview(spinner)
        bg.addSubview(title)
        bg.addSubview(label)
        panel.contentView = bg
    }

    private func showHUD() {
        if !panel.isVisible {
            placeHUD()
            panel.orderFrontRegardless()
            Log.write("showHUD frame=\(panel.frame) visible=\(panel.isVisible) screen=\(panel.screen?.frame ?? .zero)")
        }
    }

    private func placeHUD() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let vf = screen?.visibleFrame else { return }
        let sz = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: vf.midX - sz.width / 2, y: vf.maxY - sz.height - 18))
    }

    private func hideHUD() {
        panel?.orderOut(nil)
        closeAt = nil
        setIcon("mic")          // после завершения — снова микрофон
        Log.write("hideHUD")
    }

    private func busy(_ on: Bool) {
        if on { spinner.isHidden = false; spinner.startAnimation(nil) }
        else { spinner.stopAnimation(nil); spinner.isHidden = true }
    }

    private func tick() {
        if let closeAt, Date() >= closeAt { hideHUD(); return }
        guard let raw = try? String(contentsOf: Paths.status, encoding: .utf8) else { return }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let parts = text.split(separator: "|", maxSplits: 1).map(String.init)
        let state = parts[0]
        let msg = parts.count > 1 ? parts[1] : ""
        guard state != lastState else { return }

        lastState = state
        closeAt = nil
        Log.write("state=\(state) msg=\(msg)")

        switch state {
        case "preparing":
            showHUD(); busy(true); label.stringValue = msg.isEmpty ? "🎤 Готовлю микрофон…" : msg
            setIcon("waveform")
        case "recording":
            showHUD(); busy(true); label.stringValue = msg.isEmpty ? "🎤 Слушаю…" : msg
            setIcon("waveform")
        case "transcribing":
            showHUD(); busy(true); label.stringValue = msg.isEmpty ? "Распознаю…" : msg
            setIcon("waveform")
        case "fixing":
            showHUD(); busy(true); label.stringValue = msg.isEmpty ? "Исправляю через OpenCode…" : msg
            setIcon("ellipsis")
        case "done":
            showHUD(); busy(false); label.stringValue = "✅ " + (msg.isEmpty ? "Готово" : msg)
            setIcon("checkmark")
            closeAt = Date().addingTimeInterval(2.0)
        case "info":
            showHUD(); busy(false); label.stringValue = "ℹ️ " + (msg.isEmpty ? "Готово" : msg)
            setIcon("info.circle")
            closeAt = Date().addingTimeInterval(2.5)
        case "error":
            showHUD(); busy(false); label.stringValue = "⚠️ " + (msg.isEmpty ? "Ошибка" : msg)
            setIcon("exclamationmark.triangle")
            closeAt = Date().addingTimeInterval(5)
        case "idle", "quit":
            hideHUD(); setIcon("mic")
        default:
            break
        }
    }

    private func setIcon(_ name: String) {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Runvoice")
        image?.isTemplate = true
        statusItem.button?.image = image
        Log.write("icon=\(name)")
    }

    // MARK: - Разрешения

    private func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}

// MARK: - Точка входа

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
