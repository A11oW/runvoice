import AppKit
import AVFoundation
import Carbon.HIToolbox
import ApplicationServices
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - Окно настроек

final class SettingsWindow: NSWindowController, NSWindowDelegate {
    private let fixText = NSTextView()
    private var promptTestLabel: NSTextField!
    private var tabView: NSTabView!
    private var languagePopup: NSPopUpButton!
    private var micPopup: NSPopUpButton!
    private var micTestButton: NSButton!
    private var micTestLabel: NSTextField!
    private var launchCheck: NSButton!
    private var launchNote: NSTextField!
    private var providerField: NSTextField!
    private var modelField: NSTextField!
    private var baseURLField: NSTextField!
    private var apiKeyField: NSSecureTextField!
    private var modeControl: NSSegmentedControl!
    private var testButton: NSButton!
    private var testResultLabel: NSTextField!
    private var aiHint: NSTextField!
    private var providerGroup: NSStackView!
    private var modelGroup: NSStackView!
    private var baseURLGroup: NSStackView!
    private var apiKeyGroup: NSStackView!
    private var restoreCheck: NSButton!
    private var hudCheck: NSButton!
    private var resetButton: NSButton!
    private var versionLabel: NSTextField!
    private var toggleHotkeyButton: NSButton!
    private var accessLabel: NSTextField!
    private var accessButton: NSButton!
    private var modelsStack: NSStackView!
    private var modelsDiskLabel: NSTextField!
    private var modelDirs: [String] = []
    private var hiddenModelPaths: [String] = []
    private var selectedModelPath = ""
    private var downloads: [String: ModelDownloader] = [:]
    private var downloadProgress: [String: Double] = [:]
    private var downloadBars: [String: NSProgressIndicator] = [:]
    private var downloadPercents: [String: NSTextField] = [:]
    private var downloadSpeedLabels: [String: NSTextField] = [:]
    private var downloadSpeeds: [String: Double] = [:]
    private var depStack: NSStackView!
    private var depLabels: [NSTextField] = []
    private var refreshTimer: Timer?
    private var lastDependencyRefresh = Date.distantPast
    private var captureMonitor: Any?
    private var captureTarget: NSButton?
    private var toggleHotkey = HotKeySetting()

    private var loadedSettings = Settings()
    private var loadedLaunchAtLogin = false
    private var loadedAPIKey = ""
    private var allowClose = false

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
        allowClose = false
        loadValues()
        refreshDiagnostics(force: true)
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self, self.window?.isVisible == true else { timer.invalidate(); return }
            self.refreshDiagnostics(force: false)
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        stopCapture()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if allowClose || !hasUnsavedChanges() { return true }
        let alert = NSAlert()
        alert.messageText = "Сохранить изменения?"
        alert.informativeText = "В настройках есть несохранённые изменения."
        alert.addButton(withTitle: "Сохранить")
        alert.addButton(withTitle: "Не сохранять")
        alert.addButton(withTitle: "Отмена")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            saveSettings()
            return false
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
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
        general.label = "Основные"
        general.view = buildGeneral()
        tabView.addTabViewItem(general)

        let models = NSTabViewItem(identifier: "models")
        models.label = "Распознавание"
        models.view = buildModels()
        tabView.addTabViewItem(models)

        let ai = NSTabViewItem(identifier: "ai")
        ai.label = "Постобработка"
        ai.view = buildAI()
        tabView.addTabViewItem(ai)

        let prompt = NSTabViewItem(identifier: "prompt")
        prompt.label = "Промпт"
        prompt.view = buildPrompt()
        tabView.addTabViewItem(prompt)

        let hotkeys = NSTabViewItem(identifier: "hotkeys")
        hotkeys.label = "Хоткеи"
        hotkeys.view = buildHotkeys()
        tabView.addTabViewItem(hotkeys)

        resetButton = NSButton(title: "Сбросить вкладку", target: self, action: #selector(resetDefaults))
        let logButton = NSButton(title: "Лог", target: self, action: #selector(openLog))
        let dataButton = NSButton(title: "Данные", target: self, action: #selector(openData))
        logButton.bezelStyle = .inline
        dataButton.bezelStyle = .inline

        versionLabel = NSTextField(labelWithString: "")
        versionLabel.font = .systemFont(ofSize: 10)
        versionLabel.textColor = .secondaryLabelColor
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        versionLabel.stringValue = (build.isEmpty || build == version) ? "v\(version)" : "v\(version) (\(build))"

        let footer = NSStackView(views: [resetButton, logButton, dataButton, versionLabel])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10
        footer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(footer)

        let cancel = NSButton(title: "Отмена", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Сохранить", target: self, action: #selector(saveSettings))
        save.keyEquivalent = "\r"

        for view in [cancel, save] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }

        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            tabView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            tabView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            tabView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),

            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),

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
        let micLabel = label("Микрофон")
        let diagLabel = label("Диагностика", bold: true)

        languagePopup = NSPopUpButton()
        languagePopup.addItems(withTitles: ["Русский", "English", "Авто"])

        micPopup = NSPopUpButton()
        micPopup.widthAnchor.constraint(equalToConstant: 230).isActive = true
        micTestButton = NSButton(title: "Проверить", target: self, action: #selector(testMicrophone))
        micTestButton.bezelStyle = .rounded
        micTestLabel = label("")
        micTestLabel.lineBreakMode = .byTruncatingTail

        let micRow = NSStackView(views: [micLabel, micPopup, micTestButton, micTestLabel])
        micRow.orientation = .horizontal
        micRow.alignment = .centerY
        micRow.spacing = 8
        micRow.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(micRow)

        restoreCheck = NSButton(checkboxWithTitle: "Возвращать прежний буфер обмена после вставки",
                                target: nil, action: nil)
        launchCheck = NSButton(checkboxWithTitle: "Запускать при входе", target: nil, action: nil)
        launchNote = label("")
        launchNote.textColor = .systemOrange
        launchNote.font = .systemFont(ofSize: 10)
        hudCheck = NSButton(checkboxWithTitle: "Показывать всплывающий бабл статуса",
                            target: nil, action: nil)

        accessLabel = label("Accessibility: проверка…")
        accessButton = NSButton(title: "Открыть настройки", target: self, action: #selector(openAccessibility))

        depStack = NSStackView()
        depStack.orientation = .vertical
        depStack.alignment = .leading
        depStack.spacing = 4
        depStack.translatesAutoresizingMaskIntoConstraints = false
        depLabels = Dependency.diagnosticsCases.map { _ in
            let field = label("")
            field.lineBreakMode = .byTruncatingMiddle
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return field
        }
        for depLabel in depLabels {
            depLabel.translatesAutoresizingMaskIntoConstraints = false
            depStack.addArrangedSubview(depLabel)
            depLabel.widthAnchor.constraint(equalTo: depStack.widthAnchor).isActive = true
        }

        let views: [NSView] = [languageLabel, languagePopup, micRow, restoreCheck,
                               launchCheck, launchNote, hudCheck,
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

            micRow.topAnchor.constraint(equalTo: languageLabel.bottomAnchor, constant: 14),
            micRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            micRow.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),

            restoreCheck.topAnchor.constraint(equalTo: micRow.bottomAnchor, constant: 16),
            restoreCheck.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),

            launchCheck.topAnchor.constraint(equalTo: restoreCheck.bottomAnchor, constant: 8),
            launchCheck.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),

            launchNote.topAnchor.constraint(equalTo: launchCheck.bottomAnchor, constant: 2),
            launchNote.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 36),

            hudCheck.topAnchor.constraint(equalTo: launchNote.bottomAnchor, constant: 8),
            hudCheck.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),

            diagLabel.topAnchor.constraint(equalTo: hudCheck.bottomAnchor, constant: 24),
            diagLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),

            accessLabel.centerYAnchor.constraint(equalTo: accessButton.centerYAnchor),
            accessLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            accessButton.topAnchor.constraint(equalTo: diagLabel.bottomAnchor, constant: 8),
            accessButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            depStack.topAnchor.constraint(equalTo: accessButton.bottomAnchor, constant: 10),
            depStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            depStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
        ])

        return view
    }

    // MARK: - AI

    private func buildAI() -> NSView {
        let view = NSView()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor),
        ])

        let modeLabel = label("Способ обработки")
        modeControl = NSSegmentedControl(labels: ["OpenCode", "Свой API", "Без правки"],
                                         trackingMode: .selectOne,
                                         target: self,
                                         action: #selector(aiModeChanged))
        modeControl.segmentStyle = .rounded
        let modeRow = NSStackView(views: [modeLabel, modeControl])
        modeRow.orientation = .horizontal
        modeRow.alignment = .centerY
        modeRow.spacing = 12

        providerField = NSTextField()
        providerField.placeholderString = "deepseek"
        modelField = NSTextField()
        modelField.placeholderString = "deepseek-flash"
        baseURLField = NSTextField()
        baseURLField.placeholderString = "https://api.example.com/v1"
        apiKeyField = NSSecureTextField()
        apiKeyField.placeholderString = "если нужен"

        providerGroup = fieldGroup("Провайдер", field: providerField)
        modelGroup = fieldGroup("Модель", field: modelField)
        baseURLGroup = fieldGroup("Базовый URL (OpenAI-compatible)", field: baseURLField)
        apiKeyGroup = fieldGroup("API-ключ (хранится в Keychain)", field: apiKeyField)

        testButton = NSButton(title: "Проверить подключение", target: self, action: #selector(testCorrection))
        testButton.bezelStyle = .rounded
        testResultLabel = NSTextField(wrappingLabelWithString: "")
        testResultLabel.font = .systemFont(ofSize: 11)
        testResultLabel.textColor = .secondaryLabelColor
        testResultLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let testRow = NSStackView(views: [testButton, testResultLabel])
        testRow.orientation = .horizontal
        testRow.alignment = .centerY
        testRow.spacing = 10

        aiHint = NSTextField(wrappingLabelWithString: "")
        aiHint.font = .systemFont(ofSize: 11)
        aiHint.textColor = .secondaryLabelColor

        let rows: [NSView] = [modeRow, providerGroup, modelGroup, baseURLGroup, apiKeyGroup, testRow, aiHint]
        for row in rows {
            stack.addArrangedSubview(row)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }

        return view
    }

    private func fieldGroup(_ title: String, field: NSTextField) -> NSStackView {
        let label = label(title)
        let stack = NSStackView(views: [label, field])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        field.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    @objc private func aiModeChanged() {
        let mode = selectedProcessingMode
        providerGroup?.isHidden = mode != "opencode"
        modelGroup?.isHidden = mode == "off"
        baseURLGroup?.isHidden = mode != "direct"
        apiKeyGroup?.isHidden = mode != "direct"
        testButton?.isEnabled = mode != "off"
        testResultLabel?.stringValue = ""
        switch mode {
        case "direct":
            aiHint?.stringValue = "Запросы уходят напрямую в {URL}/chat/completions. Ключ хранится в Keychain и передаётся как Bearer."
        case "off":
            aiHint?.stringValue = "Постобработка выключена: вставляется сырой текст Whisper."
        default:
            aiHint?.stringValue = "Запросы идут через OpenCode CLI. Провайдер и модель должны быть доступны в OpenCode."
        }
    }

    private var selectedProcessingMode: String {
        switch modeControl?.selectedSegment ?? 0 {
        case 1: return "direct"
        case 2: return "off"
        default: return "opencode"
        }
    }

    // MARK: - Модели

    private func buildModels() -> NSView {
        let view = NSView()

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        view.addSubview(scroll)

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc

        modelsStack = NSStackView()
        modelsStack.orientation = .vertical
        modelsStack.alignment = .leading
        modelsStack.spacing = 10
        modelsStack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        modelsStack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(modelsStack)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            modelsStack.topAnchor.constraint(equalTo: doc.topAnchor),
            modelsStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            modelsStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            modelsStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])

        return view
    }

    private func refreshModels() {
        guard modelsStack != nil else { return }

        for sub in modelsStack.arrangedSubviews {
            modelsStack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }
        downloadBars.removeAll()
        downloadPercents.removeAll()
        downloadSpeedLabels.removeAll()
        downloadSpeeds.removeAll()

        let active = WhisperModelStore.file(at: selectedModelPath)
        var found = WhisperModelStore.foundModels(extraDirectories: modelDirs,
                                                  excluding: hiddenModelPaths)
        if let active, !found.contains(where: { $0.path == active.path }) {
            found.insert(active, at: 0)
        }

        // Баннер состояния
        let banner = NSTextField(wrappingLabelWithString: "")
        banner.font = .systemFont(ofSize: 12)
        if selectedModelPath.isEmpty {
            banner.stringValue = "Модель не выбрана. Скачайте модель или добавьте уже скачанную."
            banner.textColor = .systemOrange
        } else if let active {
            banner.stringValue = "Активная модель: \(active.fileName) · \(active.sizeText)"
            banner.textColor = .secondaryLabelColor
        } else {
            banner.stringValue = "Выбранная модель недоступна: \(selectedModelPath)"
            banner.textColor = .systemOrange
        }
        addRow(banner)

        let foundHeader = NSStackView()
        foundHeader.orientation = .horizontal
        foundHeader.alignment = .centerY
        foundHeader.spacing = 8
        foundHeader.addArrangedSubview(sectionLabel("Найдены на компьютере"))
        let foundSpacer = NSView()
        foundSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        foundHeader.addArrangedSubview(foundSpacer)
        let refresh = NSButton(title: "Обновить", target: self, action: #selector(refreshModelsList))
        refresh.bezelStyle = .inline
        foundHeader.addArrangedSubview(refresh)
        addRow(foundHeader)

        if found.isEmpty {
            let empty = NSTextField(labelWithString: "Модели ggml-*.bin не найдены.")
            empty.font = .systemFont(ofSize: 11)
            empty.textColor = .secondaryLabelColor
            addRow(empty)
        } else {
            for model in found { addRow(modelRow(model)) }
        }

        if !hiddenModelPaths.isEmpty {
            addRow(sectionLabel("Скрытые модели"))
            for path in hiddenModelPaths {
                addRow(hiddenModelRow(path))
            }
        }

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let addFile = NSButton(title: "Добавить файл…", target: self, action: #selector(addModelFile))
        addFile.bezelStyle = .rounded
        let addFolder = NSButton(title: "Добавить папку…", target: self, action: #selector(addModelFolder))
        addFolder.bezelStyle = .rounded
        let openFolder = NSButton(title: "Открыть папку моделей", target: self, action: #selector(openModelsFolder))
        openFolder.bezelStyle = .rounded
        buttons.addArrangedSubview(addFile)
        buttons.addArrangedSubview(addFolder)
        buttons.addArrangedSubview(openFolder)
        addRow(buttons)

        if !modelDirs.isEmpty {
            addRow(sectionLabel("Папки"))
            for dir in modelDirs { addRow(folderRow(dir)) }
        }

        let hiddenNames = Set(hiddenModelPaths.map { URL(fileURLWithPath: $0).lastPathComponent })
        let missing = WhisperModelCatalog.models
            .filter { model in
                !hiddenNames.contains(model.fileName)
                    && !found.contains(where: { $0.fileName == model.fileName })
            }
            .sorted { a, b in
                if a.recommended != b.recommended { return a.recommended }
                return a.sizeBytes < b.sizeBytes
            }
        if !missing.isEmpty {
            addRow(sectionLabel("Скачать"))
            for model in missing { addRow(downloadRow(model)) }
        }

        addRow(sectionLabel("Хранилище"))
        modelsDiskLabel = NSTextField(labelWithString: "")
        modelsDiskLabel.font = .systemFont(ofSize: 11)
        modelsDiskLabel.textColor = .secondaryLabelColor
        updateDiskLabel()
        addRow(modelsDiskLabel)
    }

    private func addRow(_ view: NSView) {
        modelsStack.addArrangedSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: modelsStack.widthAnchor, constant: -32).isActive = true
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12, weight: .bold)
        field.textColor = .secondaryLabelColor
        return field
    }

    private func displayTitle(for model: WhisperModelFile) -> String {
        WhisperModelCatalog.models.first { $0.fileName == model.fileName }?.title ?? model.fileName
    }

    private func hiddenModelRow(_ path: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let file = WhisperModelStore.file(at: path)
        let title = NSTextField(labelWithString: file?.fileName ?? path)
        title.font = .systemFont(ofSize: 12)
        title.lineBreakMode = .byTruncatingMiddle
        let subtitle = NSTextField(labelWithString: file.map { "\($0.sizeText) · скрыта" } ?? "файл не найден")
        subtitle.font = .systemFont(ofSize: 10)
        subtitle.textColor = .secondaryLabelColor
        let text = NSStackView(views: [title, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let restore = NSButton(title: "Вернуть", target: self, action: #selector(unhideModel(_:)))
        restore.bezelStyle = .inline
        restore.identifier = NSUserInterfaceItemIdentifier(path)

        row.addArrangedSubview(text)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(restore)
        return row
    }

    private func folderRow(_ dir: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let label = NSTextField(labelWithString: dir)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = "Файлы в этой папке не удаляются"

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let remove = NSButton(title: "Убрать", target: self, action: #selector(removeFolder(_:)))
        remove.bezelStyle = .inline
        remove.identifier = NSUserInterfaceItemIdentifier(dir)
        remove.toolTip = "Убрать папку из списка; файлы останутся на диске"

        row.addArrangedSubview(label)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(remove)
        return row
    }

    @objc private func refreshModelsList() {
        refreshModels()
        refreshDiagnostics(force: true)
    }

    @objc private func openModelsFolder() {
        NSWorkspace.shared.open(WhisperModelStore.modelsDirectory)
    }

    @objc private func unhideModel(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        hiddenModelPaths.removeAll { $0 == path }
        refreshModels()
    }

    @objc private func removeFolder(_ sender: NSButton) {
        guard let dir = sender.identifier?.rawValue else { return }
        modelDirs.removeAll { $0 == dir }
        refreshModels()
    }

    private func modelRow(_ model: WhisperModelFile) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let radio = NSButton(radioButtonWithTitle: "", target: self, action: #selector(selectModel(_:)))
        radio.identifier = NSUserInterfaceItemIdentifier(model.path)
        radio.state = (model.path == selectedModelPath) ? .on : .off
        radio.setContentHuggingPriority(.required, for: .horizontal)

        let title = NSButton(title: displayTitle(for: model),
                             target: self, action: #selector(selectModel(_:)))
        title.isBordered = false
        title.alignment = .left
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.identifier = NSUserInterfaceItemIdentifier(model.path)

        let subtitle = NSTextField(labelWithString: "\(model.sizeText) · \(model.directory)")
        subtitle.font = .systemFont(ofSize: 10)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingMiddle

        let text = NSStackView(views: [title, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let reveal = NSButton(title: "Показать в Finder", target: self, action: #selector(revealModel(_:)))
        reveal.bezelStyle = .inline
        reveal.identifier = NSUserInterfaceItemIdentifier(model.path)

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        row.addArrangedSubview(radio)
        row.addArrangedSubview(text)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(reveal)

        if model.isManaged {
            let delete = NSButton(title: "Удалить", target: self, action: #selector(deleteModel(_:)))
            delete.bezelStyle = .inline
            delete.identifier = NSUserInterfaceItemIdentifier(model.path)
            row.addArrangedSubview(delete)
        } else {
            let hide = NSButton(title: "Скрыть", target: self, action: #selector(hideModel(_:)))
            hide.bezelStyle = .inline
            hide.identifier = NSUserInterfaceItemIdentifier(model.path)
            hide.toolTip = "Убрать модель из списка; файл на диске останется"
            row.addArrangedSubview(hide)
        }
        return row
    }

    private func downloadRow(_ model: WhisperModel) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 4

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10

        let title = NSTextField(labelWithString: model.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let subtitle = NSTextField(labelWithString: model.sizeText)
        subtitle.font = .systemFont(ofSize: 10)
        subtitle.textColor = .secondaryLabelColor

        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        let free = (attrs?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        let notEnoughSpace = free < model.sizeBytes + 200 * 1024 * 1024

        let recommended = NSTextField(labelWithString: "Рекомендуется")
        recommended.font = .systemFont(ofSize: 10, weight: .medium)
        recommended.textColor = .systemGreen
        recommended.isHidden = !model.recommended

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let percent = NSTextField(labelWithString: "")
        percent.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        percent.textColor = .secondaryLabelColor
        percent.isHidden = downloads[model.id] == nil
        if let value = downloadProgress[model.id] {
            percent.stringValue = "\(Int(value * 100))%"
        }

        let button = NSButton(title: downloads[model.id] == nil ? "Скачать" : "Отмена",
                              target: self, action: #selector(downloadModel(_:)))
        button.bezelStyle = .rounded
        button.identifier = NSUserInterfaceItemIdentifier(model.id)
        button.isEnabled = downloads[model.id] != nil || !notEnoughSpace
        button.toolTip = notEnoughSpace ? "Недостаточно свободного места" : nil

        header.addArrangedSubview(title)
        header.addArrangedSubview(subtitle)
        header.addArrangedSubview(recommended)
        header.addArrangedSubview(spacer)
        header.addArrangedSubview(percent)
        header.addArrangedSubview(button)

        let note = NSTextField(wrappingLabelWithString: model.note)
        note.font = .systemFont(ofSize: 10)
        note.textColor = notEnoughSpace ? .systemOrange : .secondaryLabelColor
        if notEnoughSpace {
            note.stringValue += " Недостаточно свободного места: нужно \(model.sizeText) плюс запас 200 МБ."
        }

        let speedLabel = NSTextField(labelWithString: "")
        speedLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        speedLabel.textColor = .secondaryLabelColor
        speedLabel.isHidden = downloads[model.id] == nil
        if let speed = downloadSpeeds[model.id], let progress = downloadProgress[model.id] {
            speedLabel.stringValue = speedText(speed, model: model, progress: progress)
        }

        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.doubleValue = downloadProgress[model.id] ?? 0
        bar.isHidden = downloads[model.id] == nil
        bar.heightAnchor.constraint(equalToConstant: 6).isActive = true

        container.addArrangedSubview(header)
        container.addArrangedSubview(note)
        container.addArrangedSubview(speedLabel)
        container.addArrangedSubview(bar)

        header.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        note.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        speedLabel.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        bar.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true

        downloadBars[model.id] = bar
        downloadPercents[model.id] = percent
        downloadSpeedLabels[model.id] = speedLabel
        return container
    }

    private func speedText(_ speed: Double, model: WhisperModel, progress: Double) -> String {
        guard speed > 0 else { return "Загрузка…" }
        let written = Double(model.sizeBytes) * progress
        let remaining = max(0, Double(model.sizeBytes) - written)
        let seconds = remaining / speed
        let eta: String
        if seconds < 60 {
            eta = "\(max(1, Int(seconds.rounded()))) с"
        } else {
            eta = "\(max(1, Int((seconds / 60).rounded()))) мин"
        }
        return "\(WhisperSize.text(Int64(speed)))/с · осталось \(eta)"
    }

    @objc private func downloadModel(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let model = WhisperModelCatalog.models.first(where: { $0.id == id }) else { return }

        if let active = downloads[id] {
            active.cancel()
            downloads[id] = nil
            downloadProgress[id] = nil
            refreshModels()
            return
        }

        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        let free = (attrs?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        if free < model.sizeBytes + 200 * 1024 * 1024 {
            let alert = NSAlert()
            alert.messageText = "Недостаточно места"
            alert.informativeText = "Для загрузки нужно \(model.sizeText) плюс запас 200 МБ."
            alert.runModal()
            return
        }

        let downloader = ModelDownloader(model: model)
        downloads[id] = downloader
        downloadProgress[id] = 0

        downloader.onProgress = { [weak self] value, speed in
            guard let self else { return }
            self.downloadProgress[id] = value
            self.downloadSpeeds[id] = speed
            self.downloadBars[id]?.doubleValue = value
            self.downloadPercents[id]?.stringValue = "\(Int(value * 100))%"
            self.downloadPercents[id]?.isHidden = false
            self.downloadSpeedLabels[id]?.stringValue = self.speedText(speed, model: model, progress: value)
            self.downloadSpeedLabels[id]?.isHidden = false
        }
        downloader.onFinish = { [weak self] result in
            guard let self else { return }
            self.downloads[id] = nil
            self.downloadProgress[id] = nil
            self.downloadSpeeds[id] = nil
            switch result {
            case .success(let url):
                if self.selectedModelPath.isEmpty { self.selectedModelPath = url.path }
                self.refreshModels()
                self.refreshDiagnostics(force: true)
                Log.write("model: скачана \(url.lastPathComponent)")
            case .failure(let error):
                self.refreshModels()
                Log.write("model: ошибка загрузки \(model.id): \(error.localizedDescription)")
                let alert = NSAlert()
                alert.messageText = "Не удалось скачать модель"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
        downloader.start()
        refreshModels()
    }

    private func updateDiskLabel() {
        guard let modelsDiskLabel else { return }
        let fm = FileManager.default
        let managed = WhisperModelStore.foundModels()
            .filter { $0.isManaged }
            .reduce(Int64(0)) { $0 + $1.sizeBytes }
        let attrs = try? fm.attributesOfFileSystem(forPath: NSHomeDirectory())
        let free = (attrs?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        modelsDiskLabel.stringValue =
            "Скачанные приложением: \(WhisperSize.text(managed))"
            + " · свободно: \(WhisperSize.text(free))"
    }

    @objc private func selectModel(_ sender: NSButton) {
        selectedModelPath = sender.identifier?.rawValue ?? ""
        refreshModels()
    }

    @objc private func revealModel(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc private func deleteModel(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue, WhisperModelStore.isManaged(path: path) else { return }
        let alert = NSAlert()
        alert.messageText = "Удалить модель?"
        alert.informativeText = "Файл будет удалён с диска. Это действие нельзя отменить."
        alert.addButton(withTitle: "Удалить")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? FileManager.default.removeItem(atPath: path)
        if selectedModelPath == path { selectedModelPath = "" }
        refreshModels()
    }

    @objc private func hideModel(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        if !hiddenModelPaths.contains(path) { hiddenModelPaths.append(path) }
        if selectedModelPath == path { selectedModelPath = "" }
        refreshModels()
    }

    @objc private func addModelFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "bin") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard WhisperModelStore.isWhisperModel(at: url) else {
            let alert = NSAlert()
            alert.messageText = "Это не модель Whisper"
            alert.informativeText = "Нужен файл ggml-*.bin от whisper.cpp."
            alert.runModal()
            return
        }
        let dir = url.deletingLastPathComponent().path
        if !modelDirs.contains(dir) { modelDirs.append(dir) }
        hiddenModelPaths.removeAll { $0 == url.standardized.path }
        selectedModelPath = url.standardized.path
        refreshModels()
    }

    @objc private func addModelFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !modelDirs.contains(url.path) { modelDirs.append(url.path) }
        refreshModels()
    }

    // MARK: - Prompt

    private func buildPrompt() -> NSView {
        let view = NSView()
        let fixLabel = label("Промпт для исправления текста  (⌥Space)", bold: true)
        let fixHint = label("Пустое поле заменяется встроенным промптом при открытии настроек.")

        let reset = NSButton(title: "Сбросить к встроенному", target: self, action: #selector(resetPromptToDefault))
        reset.bezelStyle = .rounded
        let test = NSButton(title: "Проверить на примере", target: self, action: #selector(testPrompt))
        test.bezelStyle = .rounded
        let buttons = NSStackView(views: [reset, test])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        promptTestLabel = label("")
        promptTestLabel.lineBreakMode = .byWordWrapping
        promptTestLabel.maximumNumberOfLines = 2

        let fixScroll = makeScroll(fixText)

        fixLabel.translatesAutoresizingMaskIntoConstraints = false
        fixHint.translatesAutoresizingMaskIntoConstraints = false
        buttons.translatesAutoresizingMaskIntoConstraints = false
        promptTestLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(fixLabel)
        view.addSubview(buttons)
        view.addSubview(fixScroll)
        view.addSubview(fixHint)
        view.addSubview(promptTestLabel)

        NSLayoutConstraint.activate([
            fixLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            fixLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            fixLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            buttons.topAnchor.constraint(equalTo: fixLabel.bottomAnchor, constant: 8),
            buttons.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),

            fixScroll.topAnchor.constraint(equalTo: buttons.bottomAnchor, constant: 8),
            fixScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            fixScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            fixScroll.heightAnchor.constraint(equalToConstant: 280),

            fixHint.topAnchor.constraint(equalTo: fixScroll.bottomAnchor, constant: 6),
            fixHint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            fixHint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            promptTestLabel.topAnchor.constraint(equalTo: fixHint.bottomAnchor, constant: 4),
            promptTestLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            promptTestLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
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
        let hint = label("Кликните по сочетанию и нажмите новое. Esc — отмена.")
        let note = label("Нужен хотя бы один модификатор из ⌃ / ⌥ / ⌘.")

        toggleHotkeyButton = NSButton(title: toggleHotkey.display, target: self, action: #selector(captureToggle))
        toggleHotkeyButton.bezelStyle = .rounded

        let views: [NSView] = [toggleLabel, hint, note, toggleHotkeyButton]
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

            hint.topAnchor.constraint(equalTo: toggleLabel.bottomAnchor, constant: 22),
            hint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            note.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 4),
            note.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
        ])

        return view
    }

    // MARK: - Горячие клавиши

    @objc private func captureToggle() { startCapture(button: toggleHotkeyButton) }

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
            button.title = toggleHotkey.display
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
        Log.write("hotkey capture: key=\(event.keyCode) mods=\(mods) system=\(systemShortcutName(for: setting) ?? "-")")
        if let name = systemShortcutName(for: setting) {
            let alert = NSAlert()
            alert.messageText = "Сочетание занято macOS"
            alert.informativeText = "\(setting.display) обычно используется для «\(name)». Всё равно назначить?"
            alert.addButton(withTitle: "Назначить")
            alert.addButton(withTitle: "Отмена")
            if alert.runModal() != .alertFirstButtonReturn {
                stopCapture()
                return
            }
        }
        if captureTarget === toggleHotkeyButton {
            toggleHotkey = setting
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

    private func systemShortcutName(for hotkey: HotKeySetting) -> String? {
        let mods = hotkey.modifiers
        let cmd = (mods & UInt32(cmdKey)) != 0
        let ctrl = (mods & UInt32(controlKey)) != 0
        let opt = (mods & UInt32(optionKey)) != 0
        let shift = (mods & UInt32(shiftKey)) != 0
        let key = Int(hotkey.keyCode)

        if key == kVK_Space {
            if cmd && !ctrl && !opt { return "Spotlight" }
            if ctrl && !cmd && !opt { return "переключение источника ввода" }
            if ctrl && opt && !cmd { return "поиск в Finder" }
        }
        if key == kVK_Tab && cmd { return "переключение приложений" }
        if key == kVK_ANSI_Q && cmd && !shift { return "завершение приложения" }
        if key == kVK_ANSI_W && cmd { return "закрытие окна" }
        if key == kVK_ANSI_H && cmd { return "скрытие приложения" }
        if key == kVK_ANSI_M && cmd { return "сворачивание окна" }
        return nil
    }

    // MARK: - Диагностика

    private func refreshDiagnostics(force: Bool = false) {
        let ok = AXIsProcessTrusted()
        accessLabel.stringValue = ok ? "Accessibility: ✓ разрешено" : "Accessibility: ⚠️ нет доступа"
        accessLabel.textColor = ok ? .systemGreen : .systemOrange
        accessButton.isHidden = ok

        if !force, Date().timeIntervalSince(lastDependencyRefresh) < 5 { return }
        lastDependencyRefresh = Date()

        let settings = SettingsStore.load()
        for (index, dependency) in Dependency.diagnosticsCases.enumerated() where index < depLabels.count {
            let line = diagnosticLine(dependency, settings: settings)
            depLabels[index].stringValue = line.text
            depLabels[index].textColor = line.color
            depLabels[index].toolTip = line.text
        }
    }

    private func diagnosticLine(
        _ dependency: Dependency,
        settings: Settings
    ) -> (text: String, color: NSColor) {
        let fm = FileManager.default
        switch dependency {
        case .ffmpeg:
            if let path = Dependency.locateExecutable("ffmpeg") {
                return ("✓ ffmpeg — \(path)", .systemGreen)
            }
            return ("⚠️ ffmpeg — не найден (brew install ffmpeg)", .systemOrange)

        case .whisperServer:
            if let path = WhisperModelStore.bundledServer?.path,
               fm.isExecutableFile(atPath: path) {
                return ("✓ whisper-server (встроенный)", .systemGreen)
            }
            return ("⚠️ whisper-server — не найден в бандле", .systemOrange)

        case .whisperCli:
            if let path = WhisperModelStore.bundledCLI?.path,
               fm.isExecutableFile(atPath: path) {
                return ("✓ whisper-cli (встроенный)", .systemGreen)
            }
            return ("⚠️ whisper-cli — не найден в бандле", .systemOrange)

        case .whisperModel:
            if let model = WhisperModelStore.activeModel(settings: settings) {
                let title = WhisperModelCatalog.models
                    .first { $0.fileName == model.fileName }?.title ?? model.fileName
                let source = model.isManaged ? "скачана приложением" : model.directory
                return ("✓ Модель Whisper: \(title) · \(model.sizeText) — \(source)", .systemGreen)
            }
            if settings.whisperModelPath.isEmpty {
                return ("⚠️ Модель Whisper не выбрана — Настройки → Модели", .systemOrange)
            }
            return ("⚠️ Модель Whisper недоступна: \(settings.whisperModelPath)", .systemOrange)

        case .vadModel:
            if let path = WhisperModelStore.bundledVAD?.path,
               fm.fileExists(atPath: path) {
                return ("✓ VAD-модель (встроенная)", .systemGreen)
            }
            return ("⚠️ VAD-модель — не найдена в бандле", .systemOrange)

        case .opencode:
            if !settings.useOpenCode {
                return ("– OpenCode CLI (не используется)", .secondaryLabelColor)
            }
            if let path = OpenCodeLocator.find() {
                return ("✓ OpenCode CLI — \(path)", .systemGreen)
            }
            return ("⚠️ OpenCode CLI — не найден", .systemOrange)
        }
    }

    @objc private func openAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(Paths.log)
    }

    @objc private func openData() {
        NSWorkspace.shared.open(Paths.support)
    }

    @objc private func testMicrophone() {
        let name = micPopup.titleOfSelectedItem ?? ""
        micTestButton.isEnabled = false
        micTestLabel.stringValue = "Запись 1 с…"
        micTestLabel.textColor = .secondaryLabelColor
        MicTester.test(micName: name) { [weak self] result in
            guard let self else { return }
            self.micTestButton.isEnabled = true
            switch result {
            case .success(let level):
                let value = Double(level.replacingOccurrences(of: ",", with: ".")) ?? -100
                if value > -50 {
                    self.micTestLabel.stringValue = "✓ \(level) dB"
                    self.micTestLabel.textColor = .systemGreen
                } else {
                    self.micTestLabel.stringValue = "⚠️ тишина (\(level) dB)"
                    self.micTestLabel.textColor = .systemOrange
                }
            case .failure(let error):
                self.micTestLabel.stringValue = "⚠️ \(error.localizedDescription)"
                self.micTestLabel.textColor = .systemOrange
            }
        }
    }

    @objc private func testCorrection() {
        let settings = currentSettings()
        testButton.isEnabled = false
        testResultLabel.stringValue = "Проверяю…"
        testResultLabel.textColor = .secondaryLabelColor
        CorrectionTester.test(settings: settings,
                              prompt: settings.promptFix,
                              apiKey: apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) { [weak self] result in
            guard let self else { return }
            self.testButton.isEnabled = self.selectedProcessingMode != "off"
            switch result {
            case .success(let text):
                self.testResultLabel.stringValue = "✓ \(text)"
                self.testResultLabel.textColor = .systemGreen
            case .failure(let error):
                self.testResultLabel.stringValue = "⚠️ \(error.localizedDescription)"
                self.testResultLabel.textColor = .systemOrange
            }
        }
    }

    @objc private func resetPromptToDefault() {
        fixText.string = DefaultPrompts.fix
    }

    @objc private func testPrompt() {
        let settings = currentSettings()
        promptTestLabel.stringValue = "Проверяю…"
        promptTestLabel.textColor = .secondaryLabelColor
        CorrectionTester.test(settings: settings,
                              prompt: fixText.string,
                              apiKey: apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let text):
                self.promptTestLabel.stringValue = "✓ \(text)"
                self.promptTestLabel.textColor = .systemGreen
            case .failure(let error):
                self.promptTestLabel.stringValue = "⚠️ \(error.localizedDescription)"
                self.promptTestLabel.textColor = .systemOrange
            }
        }
    }

    private func reloadMicrophones(selected: String) {
        var names = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        ).devices.map(\.localizedName)

        if names.isEmpty { names = ["MacBook Pro Microphone"] }
        if !selected.isEmpty, !names.contains(selected) { names.append(selected) }
        micPopup.removeAllItems()
        micPopup.addItems(withTitles: names)
        if let index = names.firstIndex(of: selected) {
            micPopup.selectItem(at: index)
        } else if let index = names.firstIndex(of: "MacBook Pro Microphone") {
            micPopup.selectItem(at: index)
        } else {
            micPopup.selectItem(at: 0)
        }
    }

    private func refreshLaunchStatus() {
        let status = SMAppService.mainApp.status
        loadedLaunchAtLogin = status == .enabled
        launchCheck.state = loadedLaunchAtLogin ? .on : .off
        if status == .requiresApproval {
            launchNote.stringValue = "Подтвердите в System Settings → Login Items"
            launchNote.isHidden = false
        } else {
            launchNote.stringValue = ""
            launchNote.isHidden = true
        }
    }

    private func currentSettings() -> Settings {
        var settings = loadedSettings
        settings.promptFix = fixText.string
        settings.language = languages[max(0, languagePopup.indexOfSelectedItem)]
        settings.microphone = micPopup.titleOfSelectedItem ?? ""
        settings.provider = providerField.stringValue.trimmingCharacters(in: .whitespaces)
        settings.model = modelField.stringValue.trimmingCharacters(in: .whitespaces)
        settings.baseURL = baseURLField.stringValue.trimmingCharacters(in: .whitespaces)
        settings.processingMode = selectedProcessingMode
        switch settings.processingMode {
        case "direct":
            settings.useOpenCode = false
        case "off":
            settings.useOpenCode = false
            settings.baseURL = ""
        default:
            settings.useOpenCode = true
            settings.baseURL = ""
        }
        settings.restoreClipboard = restoreCheck.state == .on
        settings.showHUD = hudCheck.state == .on
        settings.hotkeyToggle = toggleHotkey
        settings.whisperModelPath = selectedModelPath
        settings.whisperModelDirs = modelDirs
        settings.hiddenModelPaths = hiddenModelPaths
        return settings
    }

    private func hasUnsavedChanges() -> Bool {
        currentSettings() != loadedSettings
            || (launchCheck.state == .on) != loadedLaunchAtLogin
            || apiKeyField.stringValue != loadedAPIKey
    }

    private func loadValues() {
        let settings = SettingsStore.load()
        fixText.string = settings.promptFix.isEmpty ? DefaultPrompts.fix : settings.promptFix
        promptTestLabel?.stringValue = ""
        micTestLabel?.stringValue = ""

        languagePopup.selectItem(at: languages.firstIndex(of: settings.language) ?? 0)
        reloadMicrophones(selected: settings.microphone)
        providerField.stringValue = settings.provider
        modelField.stringValue = settings.model
        baseURLField.stringValue = settings.baseURL
        switch settings.processingMode {
        case "direct": modeControl.selectedSegment = 1
        case "off": modeControl.selectedSegment = 2
        default: modeControl.selectedSegment = 0
        }
        aiModeChanged()
        apiKeyField.stringValue = Keychain.value(for: Keychain.directAPIKeyAccount) ?? ""
        loadedAPIKey = apiKeyField.stringValue
        restoreCheck.state = settings.restoreClipboard ? .on : .off
        hudCheck.state = settings.showHUD ? .on : .off
        refreshLaunchStatus()

        toggleHotkey = settings.hotkeyToggle
        toggleHotkeyButton.title = toggleHotkey.display

        modelDirs = settings.whisperModelDirs
        hiddenModelPaths = settings.hiddenModelPaths
        selectedModelPath = settings.whisperModelPath
        if selectedModelPath.isEmpty,
           let auto = WhisperModelStore.activeModel(settings: settings) {
            selectedModelPath = auto.path
        }
        refreshModels()

        loadedSettings = settings
        loadedSettings.promptFix = fixText.string
        loadedSettings.whisperModelPath = selectedModelPath
        if loadedSettings.microphone.isEmpty {
            loadedSettings.microphone = micPopup.titleOfSelectedItem ?? ""
        }
    }

    @objc private func resetDefaults() {
        let tabName = tabView.selectedTabViewItem?.label ?? "вкладки"
        let confirm = NSAlert()
        confirm.messageText = "Сбросить вкладку «\(tabName)»?"
        confirm.informativeText = "Несохранённые изменения на этой вкладке будут заменены значениями по умолчанию."
        confirm.addButton(withTitle: "Сбросить")
        confirm.addButton(withTitle: "Отмена")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        switch tabView.selectedTabViewItem?.identifier as? String {
        case "prompt":
            fixText.string = DefaultPrompts.fix
        case "hotkeys":
            toggleHotkey = HotKeySetting()
            toggleHotkeyButton.title = toggleHotkey.display
        case "ai":
            providerField.stringValue = "deepseek"
            modelField.stringValue = "deepseek-flash"
            baseURLField.stringValue = ""
            apiKeyField.stringValue = ""
            modeControl.selectedSegment = 0
            aiModeChanged()
        case "models":
            modelDirs = []
            hiddenModelPaths = []
            selectedModelPath = WhisperModelStore.autoSelect(
                from: WhisperModelStore.foundModels())?.path ?? ""
            refreshModels()
        default:
            languagePopup.selectItem(at: 0)
            reloadMicrophones(selected: "")
            restoreCheck.state = .off
            hudCheck.state = .on
        }
    }

    @objc private func cancel() {
        window?.performClose(nil)
    }

    @objc private func saveSettings() {
        let settings = currentSettings()

        if settings.processingMode == "direct" {
            if settings.baseURL.isEmpty {
                let alert = NSAlert()
                alert.messageText = "Не задан базовый URL"
                alert.informativeText = "Для «Своего API» укажите базовый URL, например https://api.example.com/v1"
                alert.runModal()
                return
            }
            if !settings.baseURL.lowercased().hasPrefix("http://"),
               !settings.baseURL.lowercased().hasPrefix("https://") {
                let alert = NSAlert()
                alert.messageText = "Некорректный базовый URL"
                alert.informativeText = "URL должен начинаться с http:// или https://"
                alert.runModal()
                return
            }
        }

        let wantLaunch = launchCheck.state == .on
        if wantLaunch, SMAppService.mainApp.status != .enabled {
            do { try SMAppService.mainApp.register() }
            catch { Log.write("login item: register failed: \(error.localizedDescription)") }
        } else if !wantLaunch,
                  SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
            do { try SMAppService.mainApp.unregister() }
            catch { Log.write("login item: unregister failed: \(error.localizedDescription)") }
        }
        Log.write("login item: requested=\(wantLaunch) status=\(SMAppService.mainApp.status.rawValue)")

        let key = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            Keychain.delete(account: Keychain.directAPIKeyAccount)
        } else {
            Keychain.set(key, for: Keychain.directAPIKeyAccount)
        }

        SettingsStore.save(settings)
        loadedSettings = settings
        loadedAPIKey = key
        loadedLaunchAtLogin = SMAppService.mainApp.status == .enabled
        onSettingsSaved?()
        Log.write("settings saved")
        allowClose = true
        window?.close()
        allowClose = false
    }
}

/// Документ NSScrollView с началом координат сверху — иначе контент
/// прижимается к нижнему краю окна.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
