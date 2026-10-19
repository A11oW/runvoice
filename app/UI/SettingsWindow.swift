import AppKit
import Carbon.HIToolbox
import ApplicationServices

// MARK: - Окно настроек

final class SettingsWindow: NSWindowController, NSWindowDelegate {
    private let fixText = NSTextView()
    private let agentText = NSTextView()
    private var tabView: NSTabView!
    private var languagePopup: NSPopUpButton!
    private var providerField: NSTextField!
    private var modelField: NSTextField!
    private var baseURLField: NSTextField!
    private var useOpenCodeCheck: NSButton!
    private var restoreCheck: NSButton!
    private var hudCheck: NSButton!
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
    var onSettingsSaved: (() -> Void)?

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

        let ai = NSTabViewItem(identifier: "ai")
        ai.label = "AI"
        ai.view = buildAI()
        tabView.addTabViewItem(ai)

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
        hudCheck = NSButton(checkboxWithTitle: "Показывать всплывающий бабл статуса",
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

        let views: [NSView] = [languageLabel, languagePopup, restoreCheck, hudCheck,
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

            hudCheck.topAnchor.constraint(equalTo: restoreCheck.bottomAnchor, constant: 8),
            hudCheck.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),

            diagLabel.topAnchor.constraint(equalTo: hudCheck.bottomAnchor, constant: 24),
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

    // MARK: - AI

    private func buildAI() -> NSView {
        let view = NSView()
        let providerLabel = label("Провайдер модели правки")
        let modelLabel = label("Модель правки")
        let baseURLLabel = label("Базовый URL (OpenAI-compatible)")
        let hint = label("Пусто — через OpenCode (если включён).\nЕсли задан URL — напрямую в {URL}/chat/completions.\nБез OpenCode и без URL — текст вставится без правки.")
        let note = label("Ключ доступа, если нужен: переменная окружения OC_API_KEY.")

        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 3
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 2

        providerField = NSTextField()
        providerField.placeholderString = "deepseek"
        modelField = NSTextField()
        modelField.placeholderString = "deepseek-flash"
        baseURLField = NSTextField()
        baseURLField.placeholderString = "https://api.example.com/v1"
        useOpenCodeCheck = NSButton(checkboxWithTitle: "Использовать OpenCode CLI (если базовый URL не задан)",
                                    target: nil, action: nil)

        let views: [NSView] = [providerLabel, providerField, modelLabel, modelField,
                               baseURLLabel, baseURLField, useOpenCodeCheck, hint, note]
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

            useOpenCodeCheck.topAnchor.constraint(equalTo: baseURLField.bottomAnchor, constant: 14),
            useOpenCodeCheck.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            useOpenCodeCheck.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),

            hint.topAnchor.constraint(equalTo: useOpenCodeCheck.bottomAnchor, constant: 12),
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
        let agentLabel = label("Инструкция агенту (старт/стоп)")
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

        let settings = SettingsStore.load()
        for (index, dependency) in Dependency.allCases.enumerated() where index < depLabels.count {
            if dependency == .opencode && !settings.useOpenCode {
                depLabels[index].stringValue = "– OpenCode CLI (не используется)"
                depLabels[index].textColor = .secondaryLabelColor
                continue
            }

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
        useOpenCodeCheck.state = settings.useOpenCode ? .on : .off
        restoreCheck.state = settings.restoreClipboard ? .on : .off
        hudCheck.state = settings.showHUD ? .on : .off

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
        case "ai":
            providerField.stringValue = "deepseek"
            modelField.stringValue = "deepseek-flash"
            baseURLField.stringValue = ""
            useOpenCodeCheck.state = .on
        default:
            languagePopup.selectItem(at: 0)
            restoreCheck.state = .off
            hudCheck.state = .on
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
        settings.useOpenCode = useOpenCodeCheck.state == .on
        settings.restoreClipboard = restoreCheck.state == .on
        settings.showHUD = hudCheck.state == .on
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
        onSettingsSaved?()
        Log.write("settings saved")
        window?.close()
    }
}
