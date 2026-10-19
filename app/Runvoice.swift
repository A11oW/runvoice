// Runvoice — menu bar приложение для голосовой диктовки с коррекцией через OpenCode.
//
// Приложение само регистрирует глобальные хоткеи (Carbon, без Accessibility),
// запускает пайплайн bin/dictate.sh и показывает плавающее окно статуса.
// Вся тяжёлая работа (запись, whisper, OpenCode, вставка) остаётся в скрипте.

import AppKit
import AVFoundation
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics

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

// MARK: - Проверка зависимостей

enum OpenCodeLocator {
    static func find() -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let base = home.appendingPathComponent(".npm/_npx")
        if let dirs = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) {
            for dir in dirs {
                let path = dir.appendingPathComponent("node_modules/.bin/opencode").path
                if fm.isExecutableFile(atPath: path) { return path }
            }
        }
        let brew = "/opt/homebrew/bin/opencode"
        if fm.isExecutableFile(atPath: brew) { return brew }
        return nil
    }
}

enum Dependency: CaseIterable {
    case ffmpeg, whisperServer, whisperCli, whisperModel, vadModel, script, opencode

    var title: String {
        switch self {
        case .ffmpeg: return "ffmpeg"
        case .whisperServer: return "whisper-server"
        case .whisperCli: return "whisper-cli"
        case .whisperModel: return "Модель Whisper"
        case .vadModel: return "VAD-модель"
        case .script: return "dictate.sh"
        case .opencode: return "OpenCode CLI"
        }
    }

    var expected: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .ffmpeg: return "/opt/homebrew/bin/ffmpeg"
        case .whisperServer: return "/opt/homebrew/bin/whisper-server"
        case .whisperCli: return "/opt/homebrew/bin/whisper-cli"
        case .whisperModel:
            return home.appendingPathComponent(".local/share/whisper/ggml-large-v3-turbo-q5_0.bin").path
        case .vadModel:
            return home.appendingPathComponent(".local/share/whisper/ggml-silero-v5.1.2.bin").path
        case .script: return Paths.script?.path ?? "dictate.sh"
        case .opencode: return "npx-кэш или /opt/homebrew/bin/opencode"
        }
    }

    func isOK() -> Bool {
        let fm = FileManager.default
        switch self {
        case .ffmpeg, .whisperServer, .whisperCli:
            return fm.isExecutableFile(atPath: expected)
        case .whisperModel, .vadModel:
            return fm.fileExists(atPath: expected)
        case .script:
            guard let url = Paths.script else { return false }
            return fm.isExecutableFile(atPath: url.path)
        case .opencode:
            return OpenCodeLocator.find() != nil
        }
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

struct HotKeySetting: Codable, Equatable {
    var keyCode: UInt32 = 49                       // space
    var modifiers: UInt32 = UInt32(optionKey)      // ⌥
    var display: String = "⌥Space"
}

struct Settings: Codable {
    var promptFix = ""
    var promptAgent = ""
    var language = "ru"
    var provider = "deepseek"
    var model = "deepseek-flash"
    var baseURL = ""
    var restoreClipboard = false
    var hotkeyToggle = HotKeySetting()
    var hotkeyAgent = HotKeySetting(keyCode: 49,
                                    modifiers: UInt32(controlKey) | UInt32(shiftKey),
                                    display: "⌃⇧Space")

    enum CodingKeys: String, CodingKey {
        case promptFix, promptAgent, language, provider, model, baseURL, restoreClipboard
        case hotkeyToggle, hotkeyAgent
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        promptFix = try c.decodeIfPresent(String.self, forKey: .promptFix) ?? ""
        promptAgent = try c.decodeIfPresent(String.self, forKey: .promptAgent) ?? ""
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? "ru"
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? "deepseek"
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? "deepseek-flash"
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        restoreClipboard = try c.decodeIfPresent(Bool.self, forKey: .restoreClipboard) ?? false
        hotkeyToggle = try c.decodeIfPresent(HotKeySetting.self, forKey: .hotkeyToggle) ?? HotKeySetting()
        hotkeyAgent = try c.decodeIfPresent(HotKeySetting.self, forKey: .hotkeyAgent)
            ?? HotKeySetting(keyCode: 49,
                             modifiers: UInt32(controlKey) | UInt32(shiftKey),
                             display: "⌃⇧Space")
    }
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

final class SettingsWindow: NSWindowController, NSWindowDelegate {
    private let fixText = NSTextView()
    private let agentText = NSTextView()
    private var tabView: NSTabView!
    private var languagePopup: NSPopUpButton!
    private var providerField: NSTextField!
    private var modelField: NSTextField!
    private var baseURLField: NSTextField!
    private var restoreCheck: NSButton!
    private var toggleHotkeyButton: NSButton!
    private var agentHotkeyButton: NSButton!
    private var accessLabel: NSTextField!
    private var accessButton: NSButton!
    private var depStack: NSStackView!
    private var depLabels: [NSTextField] = []
    private var refreshTimer: Timer?
    private var captureMonitor: Any?
    private var captureTarget: NSButton?
    private var toggleHotkey = HotKeySetting()
    private var agentHotkey = HotKeySetting(keyCode: 49,
                                            modifiers: UInt32(controlKey) | UInt32(shiftKey),
                                            display: "⌃⇧Space")

    var onCaptureStateChanged: ((Bool) -> Void)?

    private let languages = ["ru", "en", "auto"]

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Runvoice — Настройки"
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        window.delegate = self
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
        refreshDiagnostics()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self, self.window?.isVisible == true else { timer.invalidate(); return }
            self.refreshDiagnostics()
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        stopCapture()
    }

    func selectTab(_ identifier: String) {
        tabView.selectTabViewItem(withIdentifier: identifier)
    }

    private func build() {
        guard let content = window?.contentView else { return }

        tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tabView)

        let general = NSTabViewItem(identifier: "general")
        general.label = "General"
        general.view = buildGeneral()
        tabView.addTabViewItem(general)

        let ae = NSTabViewItem(identifier: "ae")
        ae.label = "AE"
        ae.view = buildAE()
        tabView.addTabViewItem(ae)

        let prompt = NSTabViewItem(identifier: "prompt")
        prompt.label = "Prompt"
        prompt.view = buildPrompt()
        tabView.addTabViewItem(prompt)

        let hotkeys = NSTabViewItem(identifier: "hotkeys")
        hotkeys.label = "Hotkeys"
        hotkeys.view = buildHotkeys()
        tabView.addTabViewItem(hotkeys)

        let reset = NSButton(title: "Сбросить", target: self, action: #selector(resetDefaults))
        let cancel = NSButton(title: "Отмена", target: self, action: #selector(cancel))
        let save = NSButton(title: "Сохранить", target: self, action: #selector(saveSettings))
        save.keyEquivalent = "\r"

        for view in [reset, cancel, save] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }

        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            tabView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            tabView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            tabView.bottomAnchor.constraint(equalTo: save.topAnchor, constant: -12),

            reset.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            reset.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            save.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            save.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            cancel.trailingAnchor.constraint(equalTo: save.leadingAnchor, constant: -8),
            cancel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
    }

    // MARK: - General

    private func buildGeneral() -> NSView {
        let view = NSView()
        let languageLabel = label("Язык распознавания")
        let diagLabel = label("Диагностика", bold: true)

        languagePopup = NSPopUpButton()
        languagePopup.addItems(withTitles: ["Русский", "English", "Авто"])

        restoreCheck = NSButton(checkboxWithTitle: "Возвращать прежний буфер обмена после вставки",
                                target: nil, action: nil)

        accessLabel = label("Accessibility: проверка…")
        accessButton = NSButton(title: "Открыть настройки", target: self, action: #selector(openAccessibility))

        depStack = NSStackView()
        depStack.orientation = .vertical
        depStack.alignment = .leading
        depStack.spacing = 4
        depStack.translatesAutoresizingMaskIntoConstraints = false
        depLabels = Dependency.allCases.map { _ in label("") }
        for depLabel in depLabels {
            depLabel.translatesAutoresizingMaskIntoConstraints = false
            depStack.addArrangedSubview(depLabel)
        }

        let views: [NSView] = [languageLabel, languagePopup, restoreCheck,
                               diagLabel, accessLabel, accessButton]
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        view.addSubview(depStack)

        NSLayoutConstraint.activate([
            languageLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            languageLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            languagePopup.centerYAnchor.constraint(equalTo: languageLabel.centerYAnchor),
            languagePopup.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            languagePopup.widthAnchor.constraint(equalToConstant: 200),

            restoreCheck.topAnchor.constraint(equalTo: languageLabel.bottomAnchor, constant: 20),
            restoreCheck.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),

            diagLabel.topAnchor.constraint(equalTo: restoreCheck.bottomAnchor, constant: 24),
            diagLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),

            accessLabel.centerYAnchor.constraint(equalTo: accessButton.centerYAnchor),
            accessLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            accessButton.topAnchor.constraint(equalTo: diagLabel.bottomAnchor, constant: 8),
            accessButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            depStack.topAnchor.constraint(equalTo: accessButton.bottomAnchor, constant: 10),
            depStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            depStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
        ])

        return view
    }

    // MARK: - AE

    private func buildAE() -> NSView {
        let view = NSView()
        let providerLabel = label("Провайдер модели правки")
        let modelLabel = label("Модель правки")
        let baseURLLabel = label("Базовый URL (OpenAI-compatible)")
        let hint = label("Пусто — запрос идёт через OpenCode.\nЕсли задан — напрямую в {URL}/chat/completions.")
        let note = label("Ключ доступа, если нужен: переменная окружения OC_API_KEY.")

        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 2
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 2

        providerField = NSTextField()
        providerField.placeholderString = "deepseek"
        modelField = NSTextField()
        modelField.placeholderString = "deepseek-flash"
        baseURLField = NSTextField()
        baseURLField.placeholderString = "https://api.example.com/v1"

        let views: [NSView] = [providerLabel, providerField, modelLabel, modelField,
                               baseURLLabel, baseURLField, hint, note]
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }

        NSLayoutConstraint.activate([
            providerLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            providerLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            providerField.topAnchor.constraint(equalTo: providerLabel.bottomAnchor, constant: 6),
            providerField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            providerField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            modelLabel.topAnchor.constraint(equalTo: providerField.bottomAnchor, constant: 16),
            modelLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            modelField.topAnchor.constraint(equalTo: modelLabel.bottomAnchor, constant: 6),
            modelField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            modelField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            baseURLLabel.topAnchor.constraint(equalTo: modelField.bottomAnchor, constant: 16),
            baseURLLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            baseURLField.topAnchor.constraint(equalTo: baseURLLabel.bottomAnchor, constant: 6),
            baseURLField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            baseURLField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            hint.topAnchor.constraint(equalTo: baseURLField.bottomAnchor, constant: 12),
            hint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            hint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            note.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 6),
            note.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            note.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
        ])

        return view
    }

    // MARK: - Prompt

    private func buildPrompt() -> NSView {
        let view = NSView()
        let fixLabel = label("Промпт для исправления текста  (⌥Space)", bold: true)
        let fixHint = label("«Сбросить» вернёт встроенный текст. Изменения применяются после «Сохранить».")
        let agentLabel = label("Промпт для режима «инструкция агенту»  (⌃⇧Space)", bold: true)
        let agentHint = label("Пустое поле — используется встроенный промпт.")

        let fixScroll = makeScroll(fixText)
        let agentScroll = makeScroll(agentText)

        let views: [NSView] = [fixLabel, fixHint, agentLabel, agentHint]
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        view.addSubview(fixScroll)
        view.addSubview(agentScroll)

        NSLayoutConstraint.activate([
            fixLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            fixLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            fixLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            fixScroll.topAnchor.constraint(equalTo: fixLabel.bottomAnchor, constant: 6),
            fixScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            fixScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            fixScroll.heightAnchor.constraint(equalToConstant: 175),

            fixHint.topAnchor.constraint(equalTo: fixScroll.bottomAnchor, constant: 4),
            fixHint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            fixHint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            agentLabel.topAnchor.constraint(equalTo: fixHint.bottomAnchor, constant: 14),
            agentLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            agentLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            agentScroll.topAnchor.constraint(equalTo: agentLabel.bottomAnchor, constant: 6),
            agentScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            agentScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            agentScroll.heightAnchor.constraint(equalToConstant: 175),

            agentHint.topAnchor.constraint(equalTo: agentScroll.bottomAnchor, constant: 4),
            agentHint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            agentHint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
        ])

        return view
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

    // MARK: - Hotkeys

    private func buildHotkeys() -> NSView {
        let view = NSView()
        let toggleLabel = label("Диктовка")
        let agentLabel = label("Инструкция агенту")
        let hint = label("Кликните по сочетанию и нажмите новое. Esc — отмена.")
        let note = label("Нужен хотя бы один модификатор из ⌃ / ⌥ / ⌘.")

        toggleHotkeyButton = NSButton(title: toggleHotkey.display, target: self, action: #selector(captureToggle))
        toggleHotkeyButton.bezelStyle = .rounded
        agentHotkeyButton = NSButton(title: agentHotkey.display, target: self, action: #selector(captureAgent))
        agentHotkeyButton.bezelStyle = .rounded

        let views: [NSView] = [toggleLabel, agentLabel, hint, note, toggleHotkeyButton, agentHotkeyButton]
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }

        NSLayoutConstraint.activate([
            toggleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            toggleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            toggleHotkeyButton.centerYAnchor.constraint(equalTo: toggleLabel.centerYAnchor),
            toggleHotkeyButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            toggleHotkeyButton.widthAnchor.constraint(equalToConstant: 190),

            agentLabel.topAnchor.constraint(equalTo: toggleLabel.bottomAnchor, constant: 18),
            agentLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            agentHotkeyButton.centerYAnchor.constraint(equalTo: agentLabel.centerYAnchor),
            agentHotkeyButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            agentHotkeyButton.widthAnchor.constraint(equalToConstant: 190),

            hint.topAnchor.constraint(equalTo: agentLabel.bottomAnchor, constant: 22),
            hint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            note.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 4),
            note.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
        ])

        return view
    }

    // MARK: - Горячие клавиши

    @objc private func captureToggle() { startCapture(button: toggleHotkeyButton) }
    @objc private func captureAgent() { startCapture(button: agentHotkeyButton) }

    private func startCapture(button: NSButton) {
        stopCapture()
        captureTarget = button
        button.title = "Нажмите сочетание…"
        onCaptureStateChanged?(true)
        captureMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleCapture(event)
            return nil
        }
    }

    private func stopCapture() {
        if let monitor = captureMonitor { NSEvent.removeMonitor(monitor) }
        captureMonitor = nil
        if let button = captureTarget {
            button.title = (button === toggleHotkeyButton) ? toggleHotkey.display : agentHotkey.display
        }
        captureTarget = nil
        onCaptureStateChanged?(false)
    }

    private func handleCapture(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if event.keyCode == UInt16(kVK_Escape) && flags.isEmpty {
            stopCapture()
            return
        }

        let mods = carbonModifiers(flags)
        if mods & (UInt32(controlKey) | UInt32(optionKey) | UInt32(cmdKey)) == 0 {
            NSSound.beep()
            return
        }

        let setting = HotKeySetting(keyCode: UInt32(event.keyCode),
                                    modifiers: mods,
                                    display: displayString(keyCode: event.keyCode,
                                                           flags: flags,
                                                           characters: event.charactersIgnoringModifiers))
        if captureTarget === toggleHotkeyButton {
            toggleHotkey = setting
        } else {
            agentHotkey = setting
        }
        stopCapture()
    }

    private func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        return mods
    }

    private func displayString(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) -> String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }

        switch Int(keyCode) {
        case kVK_Space: text += "Space"
        case kVK_Return: text += "Return"
        case kVK_Tab: text += "Tab"
        case kVK_Delete: text += "Delete"
        case kVK_ForwardDelete: text += "FwdDel"
        case kVK_LeftArrow: text += "←"
        case kVK_RightArrow: text += "→"
        case kVK_UpArrow: text += "↑"
        case kVK_DownArrow: text += "↓"
        case kVK_Home: text += "Home"
        case kVK_End: text += "End"
        case kVK_PageUp: text += "PgUp"
        case kVK_PageDown: text += "PgDn"
        default:
            if let chars = characters?.uppercased(), !chars.isEmpty, chars != " " {
                text += chars
            } else {
                text += "Key\(keyCode)"
            }
        }
        return text
    }

    // MARK: - Диагностика

    private func refreshDiagnostics() {
        let ok = AXIsProcessTrusted()
        accessLabel.stringValue = ok ? "Accessibility: ✓ разрешено" : "Accessibility: ⚠️ нет доступа"
        accessLabel.textColor = ok ? .systemGreen : .systemOrange
        accessButton.isHidden = ok

        for (index, dependency) in Dependency.allCases.enumerated() where index < depLabels.count {
            let available = dependency.isOK()
            depLabels[index].stringValue = available
                ? "✓ \(dependency.title)"
                : "⚠️ \(dependency.title) — \(dependency.expected)"
            depLabels[index].textColor = available ? .systemGreen : .systemOrange
        }
    }

    @objc private func openAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func loadValues() {
        let settings = SettingsStore.load()
        fixText.string = settings.promptFix.isEmpty ? DefaultPrompts.fix : settings.promptFix
        agentText.string = settings.promptAgent.isEmpty ? DefaultPrompts.agent : settings.promptAgent

        languagePopup.selectItem(at: languages.firstIndex(of: settings.language) ?? 0)
        providerField.stringValue = settings.provider
        modelField.stringValue = settings.model
        baseURLField.stringValue = settings.baseURL
        restoreCheck.state = settings.restoreClipboard ? .on : .off

        toggleHotkey = settings.hotkeyToggle
        agentHotkey = settings.hotkeyAgent
        toggleHotkeyButton.title = toggleHotkey.display
        agentHotkeyButton.title = agentHotkey.display
    }

    @objc private func resetDefaults() {
        switch tabView.selectedTabViewItem?.identifier as? String {
        case "prompt":
            fixText.string = DefaultPrompts.fix
            agentText.string = DefaultPrompts.agent
        case "hotkeys":
            toggleHotkey = HotKeySetting()
            agentHotkey = HotKeySetting(keyCode: 49,
                                        modifiers: UInt32(controlKey) | UInt32(shiftKey),
                                        display: "⌃⇧Space")
            toggleHotkeyButton.title = toggleHotkey.display
            agentHotkeyButton.title = agentHotkey.display
        case "ae":
            providerField.stringValue = "deepseek"
            modelField.stringValue = "deepseek-flash"
            baseURLField.stringValue = ""
        default:
            languagePopup.selectItem(at: 0)
            restoreCheck.state = .off
        }
    }

    @objc private func cancel() {
        window?.close()
    }

    @objc private func saveSettings() {
        if toggleHotkey.keyCode == agentHotkey.keyCode && toggleHotkey.modifiers == agentHotkey.modifiers {
            let alert = NSAlert()
            alert.messageText = "Сочетания совпадают"
            alert.informativeText = "Задайте разные комбинации для диктовки и инструкции агенту."
            alert.runModal()
            return
        }

        var settings = SettingsStore.load()
        settings.promptFix = fixText.string
        settings.promptAgent = agentText.string
        settings.language = languages[max(0, languagePopup.indexOfSelectedItem)]
        settings.provider = providerField.stringValue.trimmingCharacters(in: .whitespaces)
        settings.model = modelField.stringValue.trimmingCharacters(in: .whitespaces)
        settings.baseURL = baseURLField.stringValue.trimmingCharacters(in: .whitespaces)
        settings.restoreClipboard = restoreCheck.state == .on
        settings.hotkeyToggle = toggleHotkey
        settings.hotkeyAgent = agentHotkey

        if !settings.baseURL.isEmpty,
           !settings.baseURL.lowercased().hasPrefix("http://"),
           !settings.baseURL.lowercased().hasPrefix("https://") {
            let alert = NSAlert()
            alert.messageText = "Некорректный базовый URL"
            alert.informativeText = "URL должен начинаться с http:// или https://"
            alert.runModal()
            return
        }

        SettingsStore.save(settings)
        Log.write("settings saved")
        window?.close()
    }
}

// MARK: - Бабл HUD

final class BubbleView: NSView {
    var bodyHeight: CGFloat = 64
    var tailX: CGFloat = 0

    private let tailWidth: CGFloat = 18
    private let tailHeight: CGFloat = 9
    private let corner: CGFloat = 14

    override func draw(_ dirtyRect: NSRect) {
        let body = NSRect(x: 0, y: 0, width: bounds.width, height: bodyHeight)
        let path = NSBezierPath(roundedRect: body, xRadius: corner, yRadius: corner)

        let minX = corner + tailWidth / 2
        let maxX = max(minX, bounds.width - corner - tailWidth / 2)
        let centerX = min(max(minX, tailX), maxX)

        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: centerX - tailWidth / 2, y: bodyHeight - 1))
        tail.line(to: NSPoint(x: centerX, y: bodyHeight + tailHeight))
        tail.line(to: NSPoint(x: centerX + tailWidth / 2, y: bodyHeight - 1))
        tail.close()

        NSColor(calibratedWhite: 0.11, alpha: 0.97).setFill()
        path.fill()
        tail.fill()
    }
}

// MARK: - Приложение

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var bubble: BubbleView!
    private var spinner: NSProgressIndicator!
    private var label: NSTextField!
    private var timer: Timer?
    private var hotkeys: [EventHotKeyRef?] = []
    private var settingsWindow: SettingsWindow?
    private var lastTrust: Bool?
    private var toggleItem: NSMenuItem?
    private var agentItem: NSMenuItem?

    private var lastState = ""
    private var closeAt: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("launch status=\(Paths.status.path) screens=\(NSScreen.screens.count)")
        let saved = SettingsStore.load()
        Log.write("settings fix=\(saved.promptFix.count) agent=\(saved.promptAgent.count)")
        Log.write("accessibility=\(AXIsProcessTrusted())")
        Log.write("deps " + Dependency.allCases.map { "\($0.title)=\($0.isOK() ? "ok" : "missing")" }.joined(separator: ", "))
        setupStatusItem()
        setupHUD()
        installHotKeyHandler()
        registerHotkeys()
        requestPermissions()

        if !AXIsProcessTrusted() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.promptForAccessibility()
            }
        }

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

        if CommandLine.arguments.contains("--snapshot-hud") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self else { return }
                self.showHUD()
                self.busy(true)
                self.label.stringValue = "🎤 Слушаю…"
                self.bubble.needsDisplay = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if let view = self.panel.contentView,
                       let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        let image = NSImage(size: view.bounds.size)
                        image.lockFocus()
                        NSColor.windowBackgroundColor.setFill()
                        view.bounds.fill()
                        if let cg = rep.cgImage, let ctx = NSGraphicsContext.current?.cgContext {
                            ctx.draw(cg, in: view.bounds)
                        }
                        image.unlockFocus()
                        if let tiff = image.tiffRepresentation,
                           let bitmap = NSBitmapImageRep(data: tiff),
                           let png = bitmap.representation(using: .png, properties: [:]) {
                            try? png.write(to: URL(fileURLWithPath: "/tmp/runvoice-hud.png"))
                        }
                    }
                    NSApp.terminate(nil)
                }
            }
        }
        if CommandLine.arguments.contains("--snapshot") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.openSettings()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    self?.snapshotSettings()
                }
            }
        }
    }

    // MARK: - Меню в строке состояния

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon("waveform")

        let menu = NSMenu()
        let header = NSMenuItem(title: "Runvoice", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        toggleItem = add(menu, "Диктовка", #selector(toggleDictation))
        agentItem = add(menu, "Инструкция агенту", #selector(agentDictation))
        menu.addItem(.separator())
        add(menu, "Настройки…", #selector(openSettings))
        menu.addItem(.separator())
        add(menu, "Открыть лог", #selector(openLog))
        add(menu, "Открыть папку данных", #selector(openData))
        menu.addItem(.separator())
        add(menu, "Выход", #selector(quit))
        statusItem.menu = menu
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc private func toggleDictation() { run("toggle") }
    @objc private func agentDictation() { run("agent") }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindow()
            settingsWindow?.onCaptureStateChanged = { [weak self] capturing in
                if capturing { self?.suspendHotkeys() } else { self?.registerHotkeys() }
            }
        }
        settingsWindow?.show()
    }

    private func snapshotSettings() {
        func capture(to path: String) {
            guard let view = settingsWindow?.window?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            let image = NSImage(size: view.bounds.size)
            image.lockFocus()
            NSColor.windowBackgroundColor.setFill()
            view.bounds.fill()
            if let cg = rep.cgImage, let ctx = NSGraphicsContext.current?.cgContext {
                ctx.draw(cg, in: view.bounds)
            }
            image.unlockFocus()
            if let tiff = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff),
               let png = bitmap.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
            }
        }

        capture(to: "/tmp/runvoice-settings.png")
        settingsWindow?.selectTab("ae")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            capture(to: "/tmp/runvoice-settings-ae.png")
            self.settingsWindow?.selectTab("prompt")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                capture(to: "/tmp/runvoice-settings-prompt.png")
                self.settingsWindow?.selectTab("hotkeys")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    capture(to: "/tmp/runvoice-settings-hotkeys.png")
                    NSApp.terminate(nil)
                }
            }
        }
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
        env["DICTATE_NO_PASTE"] = "1"     // ⌘V отправляет само приложение

        let settings = SettingsStore.load()
        if !settings.promptFix.isEmpty { env["DICTATE_PROMPT_FIX"] = settings.promptFix }
        if !settings.promptAgent.isEmpty { env["DICTATE_PROMPT_AGENT"] = settings.promptAgent }
        if !settings.language.isEmpty { env["WHISPER_LANG"] = settings.language }
        if !settings.provider.isEmpty { env["OC_PROVIDER"] = settings.provider }
        if !settings.model.isEmpty { env["OC_MODEL_ID"] = settings.model }
        if !settings.baseURL.isEmpty { env["OC_BASE_URL"] = settings.baseURL }
        if settings.restoreClipboard { env["DICTATE_RESTORE_CLIPBOARD"] = "1" }
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

    /// Отправляет ⌘V из процесса приложения (у него есть Accessibility).
    private func postPaste() {
        guard AXIsProcessTrusted() else {
            Log.write("paste: accessibility denied")
            return
        }
        let key: CGKeyCode = 9   // физическая клавиша V
        let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        usleep(30_000)
        up?.post(tap: .cghidEventTap)
        Log.write("paste: app cgEvent")
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
        suspendHotkeys()
        let settings = SettingsStore.load()
        register(id: 1, keyCode: settings.hotkeyToggle.keyCode, mods: settings.hotkeyToggle.modifiers)
        register(id: 2, keyCode: settings.hotkeyAgent.keyCode, mods: settings.hotkeyAgent.modifiers)
        toggleItem?.title = "Диктовка   \(settings.hotkeyToggle.display)"
        agentItem?.title = "Инструкция агенту   \(settings.hotkeyAgent.display)"
    }

    private func suspendHotkeys() {
        for ref in hotkeys { if let ref { UnregisterEventHotKey(ref) } }
        hotkeys.removeAll()
    }

    private func register(id: UInt32, keyCode: UInt32, mods: UInt32) {
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x52564F49), id: id) // 'RVOI'
        let status = RegisterEventHotKey(keyCode, mods, hkID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            hotkeys.append(ref)
            Log.write("hotkey registered id=\(id) key=\(keyCode) mods=\(mods)")
        } else {
            Log.write("hotkey register failed id=\(id) status=\(status)")
        }
    }

    fileprivate func hotKey(id: UInt32) {
        run(id == 2 ? "agent" : "toggle")
    }

    // MARK: - Окно статуса

    private func setupHUD() {
        let w: CGFloat = 330
        let body: CGFloat = 64
        let h: CGFloat = body + 9   // тело + хвостик

        bubble = BubbleView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        bubble.bodyHeight = body

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

        spinner = NSProgressIndicator(frame: NSRect(x: 18, y: (body - 18) / 2, width: 18, height: 18))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false

        let title = NSTextField(labelWithString: "Runvoice")
        title.frame = NSRect(x: 50, y: body - 26, width: w - 66, height: 16)
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.textColor = NSColor(white: 1, alpha: 0.55)

        label = NSTextField(labelWithString: "")
        label.frame = NSRect(x: 50, y: 16, width: w - 66, height: 20)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail

        bubble.addSubview(spinner)
        bubble.addSubview(title)
        bubble.addSubview(label)
        panel.contentView = bubble
    }

    private func showHUD() {
        if !panel.isVisible {
            placeHUD()
            panel.orderFrontRegardless()
            Log.write("showHUD frame=\(panel.frame) visible=\(panel.isVisible) screen=\(panel.screen?.frame ?? .zero)")
        }
    }

    private func placeHUD() {
        let size = panel.frame.size

        guard let button = statusItem.button, let window = button.window else {
            let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
                ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            panel.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.maxY - size.height))
            bubble.tailX = size.width / 2
            bubble.needsDisplay = true
            return
        }

        let rectInWindow = button.convert(button.bounds, to: nil)
        let screenRect = window.convertToScreen(rectInWindow)
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var x = screenRect.midX - size.width / 2
        x = max(vf.minX + 6, min(x, vf.maxX - size.width - 6))

        // хвостик смотрит в иконку, бабл висит сразу под меню-баром
        panel.setFrameOrigin(NSPoint(x: x, y: vf.maxY - size.height + 2))
        bubble.tailX = screenRect.midX - x
        bubble.needsDisplay = true
    }

    private func hideHUD() {
        panel?.orderOut(nil)
        closeAt = nil
        setIcon("waveform")     // после завершения — значок приложения
        Log.write("hideHUD")
    }

    private func busy(_ on: Bool) {
        if on { spinner.isHidden = false; spinner.startAnimation(nil) }
        else { spinner.stopAnimation(nil); spinner.isHidden = true }
    }

    private func tick() {
        let trust = AXIsProcessTrusted()
        if trust != lastTrust {
            lastTrust = trust
            Log.write("accessibility=\(trust)")
        }
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
            setIcon("mic")
        case "recording":
            showHUD(); busy(true); label.stringValue = msg.isEmpty ? "🎤 Слушаю…" : msg
            setIcon("mic")
        case "transcribing":
            showHUD(); busy(true); label.stringValue = msg.isEmpty ? "Распознаю…" : msg
            setIcon("waveform")
        case "fixing":
            showHUD(); busy(true); label.stringValue = msg.isEmpty ? "Исправляю через OpenCode…" : msg
            setIcon("ellipsis")
        case "done":
            postPaste()
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
            hideHUD()
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

    private func promptForAccessibility() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Runvoice нужен доступ Accessibility"
        alert.informativeText = "Без этого разрешения приложение не сможет вставлять распознанный текст в активное окно.\n\nВключите Runvoice в списке Accessibility."
        alert.addButton(withTitle: "Открыть настройки")
        alert.addButton(withTitle: "Позже")
        if alert.runModal() == .alertFirstButtonReturn {
            openAccessibility()
        }
    }

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
