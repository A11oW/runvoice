import AppKit
import AVFoundation
import Carbon.HIToolbox
import ApplicationServices
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - Окно настроек

final class SettingsWindow: NSWindowController, NSWindowDelegate {
    private let fixText = NSTextView()
    private let improveText = NSTextView()
    private var promptTestLabel: NSTextField!
    private var improveTestLabel: NSTextField!
    private var improveEnabledCheck: NSButton!
    private var improveGroup: NSStackView!
    private var promptSeparator: NSBox!
    private var improveSeparator: NSBox!
    private var aiScroll: NSScrollView!
    private var tabView: NSTabView!
    private var languagePopup: NSPopUpButton!
    private var micPopup: NSPopUpButton!
    private var micTestButton: NSButton!
    private var micTestLabel: NSTextField!
    private var launchCheck: NSButton!
    private var launchNote: NSTextField!
    private var dictationProviderPopup: NSPopUpButton!
    private var improveProviderPopup: NSPopUpButton!
    private var dictationProviderNote: NSTextField!
    private var improveProviderNote: NSTextField!
    private var providersStack: NSStackView!
    private var providersEmptyLabel: NSTextField!
    private var providerEditor: ProviderEditorWindow?
    private var providers: [AIProvider] = []
    private var providerKeys: [UUID: String] = [:]
    private var loadedProviderKeys: [UUID: String] = [:]
    private var dictationProviderID: UUID?
    private var improveProviderID: UUID?
    private var promptGroup: NSStackView!
    private var restoreCheck: NSButton!
    private var resetButton: NSButton!
    private var versionLabel: NSTextField!
    private var toggleHotkeyButton: NSButton!
    private var improveHotkeyButton: NSButton!
    private let stopOnEnterCheck = NSButton(checkboxWithTitle: "Останавливать распознавание по нажатию Enter", target: nil, action: nil)
    private let cancelOnEscapeCheck = NSButton(checkboxWithTitle: "Отменять диктовку по Esc", target: nil, action: nil)
    private var accessLabel: NSTextField!
    private var accessButton: NSButton!
    private var modelsStack: NSStackView!
    private var modelsDiskLabel: NSTextField!
    private var modelDirs: [String] = []
    private var hiddenModelPaths: [String] = []
    private var selectedModelPath = ""
    private var selectedEngine = "whisper"
    private let enginePopup = NSPopUpButton()
    private let vocabularyEditor = SpeechVocabularyEditor()
    private let previewControls = RecognitionPreviewControls()
    private var fluidDownload: ASRProcess?
    private var fluidDownloadProgress: Double = 0
    private var fluidStatus: NSTextField?
    private var historyTable: NSTableView!
    private var historyDetail: NSTextView!
    private var historySearch: NSSearchField!
    private var historyEnabledCheck: NSButton!
    private var historyItemsField: NSTextField!
    private var historyItemsStepper: NSStepper!
    private var historyDaysField: NSTextField!
    private var historyDaysStepper: NSStepper!
    private var historyStatusLabel: NSTextField!
    private var filteredHistory: [HistoryEntry] = []
    private var historyObserver: NSObjectProtocol?
    private lazy var historyDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
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
    private var improveHotkey = HotKeySetting.improveDefault

    private var loadedSettings = Settings()
    private var loadedLaunchAtLogin = false
    private var allowClose = false

    var onCaptureStateChanged: ((Bool) -> Void)?
    var onSettingsSaved: (() -> Void)?

    private let languages = ["ru", "en", "auto"]

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.contentMinSize = NSSize(width: 900, height: 650)
        window.minSize = NSSize(width: 900, height: 650)
        window.title = "Runvoice — Настройки"
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        window.delegate = self
        build()
        historyObserver = NotificationCenter.default.addObserver(
            forName: HistoryStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reloadHistory()
        }
    }

    deinit {
        if let historyObserver {
            NotificationCenter.default.removeObserver(historyObserver)
        }
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
        let current = window?.contentView?.bounds.size ?? NSSize(width: 900, height: 650)
        window?.setContentSize(NSSize(width: max(900, current.width),
                                      height: max(650, current.height)))
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
        let current = window?.contentView?.bounds.size ?? NSSize(width: 900, height: 650)
        let size = NSSize(width: max(900, current.width), height: max(650, current.height))
        window?.setContentSize(size)
        window?.contentView?.needsLayout = true
        window?.contentView?.layoutSubtreeIfNeeded()
        tabView.needsLayout = true
        tabView.layoutSubtreeIfNeeded()
        DispatchQueue.main.async { [weak self] in
            self?.window?.setContentSize(size)
            self?.window?.contentView?.needsLayout = true
            self?.window?.contentView?.layoutSubtreeIfNeeded()
            self?.tabView.needsLayout = true
            self?.tabView.layoutSubtreeIfNeeded()
        }
    }

    /// Только демонстрационный снимок: настройки на диске не изменяются.
    func prepareDictionarySnapshot() {
        vocabularyEditor.load(["Cypress", "Playwright", "GitHub Actions"])
    }

    /// Для отладочного скриншота: показать блок улучшения текста на вкладке «Постобработка».
    func scrollAIToImprove() {
        guard let aiScroll, let document = aiScroll.documentView, let improveGroup else { return }
        let rect = improveGroup.convert(improveGroup.bounds, to: document)
        let maxY = max(0, document.bounds.height - aiScroll.contentView.bounds.height)
        let y = min(max(0, rect.minY - 24), maxY)
        aiScroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        aiScroll.reflectScrolledClipView(aiScroll.contentView)
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

        let dictionary = NSTabViewItem(identifier: "dictionary")
        dictionary.label = "Словарь"
        dictionary.view = vocabularyEditor
        tabView.addTabViewItem(dictionary)

        let providers = NSTabViewItem(identifier: "providers")
        providers.label = "Провайдеры"
        providers.view = buildProviders()
        tabView.addTabViewItem(providers)

        let ai = NSTabViewItem(identifier: "ai")
        ai.label = "Постобработка"
        ai.view = buildAI()
        tabView.addTabViewItem(ai)

        let history = NSTabViewItem(identifier: "history")
        history.label = "История"
        history.view = buildHistory()
        tabView.addTabViewItem(history)

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
        let micLabel = label("Микрофон")
        let diagLabel = label("Диагностика", bold: true)

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

        let views: [NSView] = [micRow, restoreCheck,
                               launchCheck, launchNote,
                               diagLabel, accessLabel, accessButton]
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        view.addSubview(depStack)

        NSLayoutConstraint.activate([
            micRow.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            micRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            micRow.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),

            restoreCheck.topAnchor.constraint(equalTo: micRow.bottomAnchor, constant: 16),
            restoreCheck.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),

            launchCheck.topAnchor.constraint(equalTo: restoreCheck.bottomAnchor, constant: 8),
            launchCheck.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),

            launchNote.topAnchor.constraint(equalTo: launchCheck.bottomAnchor, constant: 2),
            launchNote.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 36),

            diagLabel.topAnchor.constraint(equalTo: launchNote.bottomAnchor, constant: 24),
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

    // MARK: - Providers

    private func buildProviders() -> NSView {
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

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 860).isActive = true
        doc.addSubview(stack)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])

        let title = label("AI-провайдеры и модели", bold: true)
        let hint = label("Здесь настраиваются профили. Какой профиль использовать для диктовки и улучшения — выбирается в «Постобработке».")
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 2

        let add = NSButton(title: "+ Добавить провайдера", target: self, action: #selector(addProvider))
        add.bezelStyle = .rounded

        providersEmptyLabel = label("Провайдеры не добавлены. Добавьте хотя бы один, чтобы использовать AI.")
        providersEmptyLabel.textColor = .secondaryLabelColor
        providersEmptyLabel.lineBreakMode = .byWordWrapping
        providersEmptyLabel.maximumNumberOfLines = 2

        providersStack = NSStackView()
        providersStack.orientation = .vertical
        providersStack.alignment = .leading
        providersStack.spacing = 8

        for row in [title, hint, add, providersEmptyLabel, providersStack] as [NSView] {
            stack.addArrangedSubview(row)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }

        return view
    }

    private func providerRow(_ provider: AIProvider) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let info = NSStackView()
        info.orientation = .vertical
        info.alignment = .leading
        info.spacing = 3

        let name = label(provider.displayTitle, bold: true)
        let details = label("\(provider.typeTitle) · \(provider.detail)")
        details.lineBreakMode = .byTruncatingMiddle
        var usageParts: [String] = []
        if provider.id == dictationProviderID { usageParts.append("диктовка") }
        if provider.id == improveProviderID { usageParts.append("улучшение") }
        let usage = label(usageParts.isEmpty
                          ? "Не используется"
                          : "Используется: " + usageParts.joined(separator: ", "))
        usage.textColor = usageParts.isEmpty ? .secondaryLabelColor : .systemGreen

        info.addArrangedSubview(name)
        info.addArrangedSubview(details)
        info.addArrangedSubview(usage)

        let edit = NSButton(title: "Изменить", target: self, action: #selector(editProvider(_:)))
        edit.bezelStyle = .rounded
        edit.identifier = NSUserInterfaceItemIdentifier(provider.id.uuidString)
        let delete = NSButton(title: "Удалить", target: self, action: #selector(deleteProvider(_:)))
        delete.bezelStyle = .rounded
        delete.identifier = NSUserInterfaceItemIdentifier(provider.id.uuidString)

        row.addArrangedSubview(info)
        row.addArrangedSubview(edit)
        row.addArrangedSubview(delete)
        info.setContentHuggingPriority(.defaultLow, for: .horizontal)
        info.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return row
    }

    private func refreshProvidersList() {
        guard providersStack != nil else { return }
        for view in providersStack.arrangedSubviews {
            providersStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        providersEmptyLabel?.isHidden = !providers.isEmpty

        for (index, provider) in providers.enumerated() {
            let row = providerRow(provider)
            row.translatesAutoresizingMaskIntoConstraints = false
            providersStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: providersStack.widthAnchor).isActive = true

            if index < providers.count - 1 {
                let separator = NSBox()
                separator.boxType = .separator
                separator.translatesAutoresizingMaskIntoConstraints = false
                providersStack.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalTo: providersStack.widthAnchor).isActive = true
            }
        }
    }

    private func refreshProviderMenus() {
        guard dictationProviderPopup != nil, improveProviderPopup != nil else { return }
        configureProviderPopup(dictationProviderPopup,
                               noneTitle: "Не использовать AI",
                               selected: dictationProviderID)
        configureProviderPopup(improveProviderPopup,
                               noneTitle: "Не выбран",
                               selected: improveProviderID)
        updateAIProviderState()
    }

    private func configureProviderPopup(_ popup: NSPopUpButton, noneTitle: String, selected: UUID?) {
        popup.removeAllItems()
        popup.addItem(withTitle: noneTitle)
        popup.lastItem?.representedObject = nil
        for provider in providers {
            popup.addItem(withTitle: "\(provider.displayTitle) — \(provider.detail)")
            popup.lastItem?.representedObject = provider.id
        }
        if let selected,
           let index = popup.itemArray.firstIndex(where: { ($0.representedObject as? UUID) == selected }) {
            popup.selectItem(at: index)
        } else {
            popup.selectItem(at: 0)
        }
        popup.isEnabled = !providers.isEmpty
    }

    private func updateAIProviderState() {
        let dictation = providers.first { $0.id == dictationProviderID }
        let improve = providers.first { $0.id == improveProviderID }

        promptGroup?.isHidden = dictation == nil
        promptSeparator?.isHidden = dictation == nil
        dictationProviderNote?.stringValue = dictation == nil
            ? "AI не используется: вставляется сырой текст Whisper."
            : "Используется для исправления распознанного текста."
        improveProviderNote?.stringValue = improve == nil
            ? (improveEnabledCheck?.state == .on
                ? "Выберите провайдера для улучшения."
                : "Улучшение выключено.")
            : "Используется при ⌥⌘E."
    }

    @objc private func addProvider() {
        let provider = AIProvider(name: "",
                                  kind: .opencode,
                                  providerID: "deepseek",
                                  model: "deepseek-flash",
                                  baseURL: "")
        showProviderEditor(provider, apiKey: "")
    }

    @objc private func editProvider(_ sender: NSButton) {
        guard let id = providerID(from: sender),
              let provider = providers.first(where: { $0.id == id }) else { return }
        showProviderEditor(provider, apiKey: providerKeys[id] ?? "")
    }

    @objc private func deleteProvider(_ sender: NSButton) {
        guard let id = providerID(from: sender),
              let provider = providers.first(where: { $0.id == id }) else { return }
        if id == dictationProviderID || id == improveProviderID {
            let alert = NSAlert()
            alert.messageText = "Провайдер используется"
            alert.informativeText = "Сначала выберите другого провайдера в «Постобработке»."
            alert.runModal()
            return
        }
        let confirm = NSAlert()
        confirm.messageText = "Удалить провайдера «\(provider.displayTitle)»?"
        confirm.informativeText = "Профиль и его API-ключ будут удалены после сохранения настроек."
        confirm.addButton(withTitle: "Удалить")
        confirm.addButton(withTitle: "Отмена")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        providers.removeAll { $0.id == id }
        providerKeys.removeValue(forKey: id)
        refreshProvidersList()
        refreshProviderMenus()
    }

    private func providerID(from sender: NSButton) -> UUID? {
        guard let raw = sender.identifier?.rawValue else { return nil }
        return UUID(uuidString: raw)
    }

    private func showProviderEditor(_ provider: AIProvider, apiKey: String) {
        let existingNames = Set(providers
            .filter { $0.id != provider.id }
            .map(\.name))
        let editor = ProviderEditorWindow(provider: provider,
                                          apiKey: apiKey,
                                          existingNames: existingNames)
        editor.onSave = { [weak self] updated, key in
            guard let self else { return }
            let wasEmpty = self.providers.isEmpty
            if let index = self.providers.firstIndex(where: { $0.id == updated.id }) {
                self.providers[index] = updated
            } else {
                self.providers.append(updated)
            }
            self.providerKeys[updated.id] = updated.kind.usesAPIKey ? key : ""

            if wasEmpty {
                self.dictationProviderID = updated.id
                self.improveProviderID = updated.id
            }
            self.refreshProvidersList()
            self.refreshProviderMenus()
        }
        providerEditor = editor
        guard let editorWindow = editor.window else { return }
        NSApp.activate(ignoringOtherApps: true)
        editorWindow.center()
        editorWindow.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: editorWindow)
        providerEditor = nil
    }

    // MARK: - Postprocessing

    private func buildAI() -> NSView {
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
        aiScroll = scroll

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 860).isActive = true
        doc.addSubview(stack)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])

        let dictationHeader = label("Провайдер для диктовки", bold: true)
        dictationProviderPopup = NSPopUpButton()
        dictationProviderPopup.target = self
        dictationProviderPopup.action = #selector(dictationProviderChanged)
        dictationProviderPopup.widthAnchor.constraint(equalToConstant: 430).isActive = true
        let dictationHint = label("Модели и подключения настраиваются во вкладке «Провайдеры».")
        dictationProviderNote = label("")
        dictationProviderNote.lineBreakMode = .byWordWrapping
        dictationProviderNote.maximumNumberOfLines = 2

        promptSeparator = NSBox()
        promptSeparator.boxType = .separator
        promptGroup = buildPromptSection()

        improveSeparator = NSBox()
        improveSeparator.boxType = .separator
        improveGroup = buildImproveSection()

        let rows: [NSView] = [dictationHeader, dictationProviderPopup, dictationHint,
                              dictationProviderNote, promptSeparator, promptGroup,
                              improveSeparator, improveGroup]
        for row in rows {
            stack.addArrangedSubview(row)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }

        return view
    }

    @objc private func dictationProviderChanged() {
        dictationProviderID = dictationProviderPopup.selectedItem?.representedObject as? UUID
        updateAIProviderState()
        refreshProvidersList()
    }

    @objc private func improveProviderChanged() {
        improveProviderID = improveProviderPopup.selectedItem?.representedObject as? UUID
        updateAIProviderState()
        refreshProvidersList()
    }

    @objc private func improveEnabledChanged() {
        updateAIProviderState()
    }

    // MARK: - История

    private func buildHistory() -> NSView {
        let view = NSView()

        historyEnabledCheck = NSButton(checkboxWithTitle: "Сохранять историю распознаваний",
                                       target: nil, action: nil)
        historySearch = NSSearchField()
        historySearch.placeholderString = "Поиск по тексту"
        historySearch.delegate = self
        historySearch.widthAnchor.constraint(equalToConstant: 240).isActive = true
        let refresh = NSButton(title: "Обновить", target: self, action: #selector(reloadHistoryAction))
        refresh.bezelStyle = .inline

        let topRow = NSStackView(views: [historyEnabledCheck, historySearch, refresh])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 10

        historyItemsField = NSTextField(string: "100")
        historyItemsField.alignment = .right
        historyItemsField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        historyItemsField.widthAnchor.constraint(equalToConstant: 56).isActive = true
        historyItemsField.target = self
        historyItemsField.action = #selector(historyItemsFieldChanged)
        historyItemsStepper = NSStepper()
        historyItemsStepper.minValue = 1
        historyItemsStepper.maxValue = 1000
        historyItemsStepper.increment = 10
        historyItemsStepper.target = self
        historyItemsStepper.action = #selector(historyItemsStepperChanged)

        historyDaysField = NSTextField(string: "30")
        historyDaysField.alignment = .right
        historyDaysField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        historyDaysField.widthAnchor.constraint(equalToConstant: 56).isActive = true
        historyDaysField.target = self
        historyDaysField.action = #selector(historyDaysFieldChanged)
        historyDaysStepper = NSStepper()
        historyDaysStepper.minValue = 1
        historyDaysStepper.maxValue = 3650
        historyDaysStepper.increment = 7
        historyDaysStepper.target = self
        historyDaysStepper.action = #selector(historyDaysStepperChanged)

        let limitsRow = NSStackView(views: [
            label("Хранить последних"), historyItemsField, historyItemsStepper,
            label("сообщений"), label("Удалять старше"), historyDaysField,
            historyDaysStepper, label("дней"),
        ])
        limitsRow.orientation = .horizontal
        limitsRow.alignment = .centerY
        limitsRow.spacing = 6

        historyTable = NSTableView()
        historyTable.rowHeight = 26
        historyTable.usesAlternatingRowBackgroundColors = true
        historyTable.dataSource = self
        historyTable.delegate = self
        historyTable.target = self
        historyTable.doubleAction = #selector(copySelectedHistory)
        historyTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let dateColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("date"))
        dateColumn.title = "Когда"
        dateColumn.width = 120
        let textColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("text"))
        textColumn.title = "Текст"
        textColumn.width = 500
        historyTable.addTableColumn(dateColumn)
        historyTable.addTableColumn(textColumn)
        historyTable.headerView = NSTableHeaderView()

        let tableScroll = NSScrollView()
        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        tableScroll.hasVerticalScroller = true
        tableScroll.autohidesScrollers = true
        tableScroll.borderType = .bezelBorder
        tableScroll.documentView = historyTable
        tableScroll.heightAnchor.constraint(equalToConstant: 190).isActive = true

        let detailTitle = label("Текст", bold: true)
        historyStatusLabel = label("")
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let copy = NSButton(title: "Копировать", target: self, action: #selector(copySelectedHistory))
        copy.bezelStyle = .rounded
        let delete = NSButton(title: "Удалить", target: self, action: #selector(deleteSelectedHistory))
        delete.bezelStyle = .rounded
        let detailHeader = NSStackView(views: [detailTitle, historyStatusLabel, spacer, copy, delete])
        detailHeader.orientation = .horizontal
        detailHeader.alignment = .centerY
        detailHeader.spacing = 8

        historyDetail = NSTextView()
        historyDetail.isEditable = false
        historyDetail.isSelectable = true
        historyDetail.font = .systemFont(ofSize: 12)
        historyDetail.textContainerInset = NSSize(width: 6, height: 6)
        historyDetail.string = "Выберите запись в списке."
        let detailScroll = makeScroll(historyDetail)
        historyDetail.font = .systemFont(ofSize: 12)
        detailScroll.heightAnchor.constraint(equalToConstant: 130).isActive = true

        let clear = NSButton(title: "Очистить историю", target: self, action: #selector(clearHistory))
        clear.bezelStyle = .rounded

        let views: [NSView] = [topRow, limitsRow, tableScroll, detailHeader, detailScroll, clear]
        for item in views {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }

        NSLayoutConstraint.activate([
            topRow.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            topRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            topRow.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),

            limitsRow.topAnchor.constraint(equalTo: topRow.bottomAnchor, constant: 10),
            limitsRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),

            tableScroll.topAnchor.constraint(equalTo: limitsRow.bottomAnchor, constant: 10),
            tableScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            tableScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            detailHeader.topAnchor.constraint(equalTo: tableScroll.bottomAnchor, constant: 10),
            detailHeader.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            detailHeader.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            detailScroll.topAnchor.constraint(equalTo: detailHeader.bottomAnchor, constant: 4),
            detailScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            detailScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            clear.topAnchor.constraint(equalTo: detailScroll.bottomAnchor, constant: 8),
            clear.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            clear.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -12),
        ])

        return view
    }

    private func reloadHistory() {
        guard historyTable != nil else { return }
        HistoryStore.shared.load()
        let query = historySearch?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let all = HistoryStore.shared.entries
        if query.isEmpty {
            filteredHistory = all
        } else {
            filteredHistory = all.filter {
                $0.text.localizedCaseInsensitiveContains(query)
                    || ($0.raw?.localizedCaseInsensitiveContains(query) ?? false)
            }
        }
        historyTable.reloadData()
        historyStatusLabel?.stringValue = "Записей: \(filteredHistory.count)"
        if filteredHistory.isEmpty {
            historyTable.deselectAll(nil)
            historyDetail?.string = "Выберите запись в списке."
        } else {
            historyTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            historyDetail?.string = filteredHistory[0].text
        }
    }

    @objc private func reloadHistoryAction() {
        reloadHistory()
    }

    @objc private func historyItemsStepperChanged() {
        historyItemsField.integerValue = historyItemsStepper.integerValue
    }

    @objc private func historyItemsFieldChanged() {
        historyItemsStepper.integerValue = historyItemsField.integerValue
    }

    @objc private func historyDaysStepperChanged() {
        historyDaysField.integerValue = historyDaysStepper.integerValue
    }

    @objc private func historyDaysFieldChanged() {
        historyDaysStepper.integerValue = historyDaysField.integerValue
    }

    @objc private func copySelectedHistory() {
        let row = historyTable?.selectedRow ?? -1
        guard row >= 0, row < filteredHistory.count else {
            historyStatusLabel?.stringValue = "Выберите запись"
            return
        }
        let text = filteredHistory[row].text
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        historyStatusLabel?.stringValue = "Скопировано"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.historyStatusLabel.stringValue == "Скопировано" else { return }
            self.historyStatusLabel.stringValue = "Записей: \(self.filteredHistory.count)"
        }
    }

    @objc private func deleteSelectedHistory() {
        let row = historyTable?.selectedRow ?? -1
        guard row >= 0, row < filteredHistory.count else { return }
        let entry = filteredHistory[row]
        let alert = NSAlert()
        alert.messageText = "Удалить запись?"
        alert.informativeText = "Текст будет удалён из истории."
        alert.addButton(withTitle: "Удалить")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        HistoryStore.shared.delete(id: entry.id)
        reloadHistory()
    }

    @objc private func clearHistory() {
        guard !HistoryStore.shared.entries.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Очистить историю?"
        alert.informativeText = "Все сохранённые распознавания будут удалены."
        alert.addButton(withTitle: "Очистить")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        HistoryStore.shared.clear()
        reloadHistory()
    }

    // MARK: - Модели

    private func buildModels() -> NSView {
        let view = NSView()
        languagePopup = NSPopUpButton()
        languagePopup.addItems(withTitles: ["Русский", "English", "Авто"])
        languagePopup.setAccessibilityLabel("Язык распознавания")
        enginePopup.addItems(withTitles: ["Whisper · Metal / CPU", "Nemotron Multilingual · потоковый"])
        enginePopup.autoenablesItems = false
        enginePopup.target = self
        enginePopup.action = #selector(changeRecognitionEngine)
        enginePopup.item(at: 1)?.isEnabled = FluidModelStore.supported

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

        let languageRow = NSStackView(views: [sectionLabel("Язык распознавания"), languagePopup])
        languageRow.orientation = .horizontal
        languageRow.alignment = .centerY
        languageRow.spacing = 16
        addRow(languageRow)

        let engineRow = NSStackView(views: [sectionLabel("Движок распознавания"), enginePopup])
        engineRow.orientation = .horizontal
        engineRow.alignment = .centerY
        engineRow.spacing = 16
        enginePopup.selectItem(at: selectedEngine == "nemotron" ? 1 : 0)
        addRow(engineRow)
        let engineNote = NSTextField(wrappingLabelWithString:
            "Whisper работает на Apple Silicon и Intel. Nemotron распознаёт речь потоком на Apple Silicon, включая русский и английский. Для смешанной речи попробуйте язык «Авто» выше.")
        engineNote.font = .systemFont(ofSize: 11)
        engineNote.textColor = .secondaryLabelColor
        addRow(engineNote)
        let fluidRow = NSStackView()
        fluidRow.orientation = .horizontal
        fluidRow.spacing = 12
        let fluidButton = NSButton(title: fluidDownload != nil ? "Отменить загрузку"
                                   : FluidModelStore.installed ? "Проверить Nemotron" : "Скачать Nemotron",
                                   target: self, action: #selector(downloadFluidModel))
        fluidButton.isEnabled = FluidModelStore.supported
        fluidRow.addArrangedSubview(fluidButton)
        let fluidStatus = NSTextField(labelWithString: fluidDownload != nil
            ? "Загрузка: \(Int(fluidDownloadProgress * 100))%"
            : FluidModelStore.installed ? "Установлена · локально, без отправки аудио"
            : "Multilingual 0.6B · требуется отдельная загрузка")
        fluidStatus.font = .systemFont(ofSize: 11)
        fluidStatus.textColor = .secondaryLabelColor
        self.fluidStatus = fluidStatus
        fluidRow.addArrangedSubview(fluidStatus)
        addRow(fluidRow)
        addRow(previewControls)
        addRow(sectionLabel("Модели Whisper · также используются как резерв для Nemotron"))

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

    private func buildImproveSection() -> NSStackView {
        let section = NSStackView()
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 6

        let header = label("Улучшение выделенного текста", bold: true)
        improveEnabledCheck = NSButton(checkboxWithTitle: "Включить улучшение выделенного текста",
                                       target: self, action: #selector(improveEnabledChanged))
        let providerLabel = label("Провайдер для улучшения")
        improveProviderPopup = NSPopUpButton()
        improveProviderPopup.target = self
        improveProviderPopup.action = #selector(improveProviderChanged)
        improveProviderPopup.widthAnchor.constraint(equalToConstant: 430).isActive = true
        improveProviderNote = label("")
        improveProviderNote.lineBreakMode = .byWordWrapping
        improveProviderNote.maximumNumberOfLines = 2

        let hint = label("Провайдер и модель выбираются здесь; профили — во вкладке «Провайдеры». Пустое поле промпта заменяется встроенным.")

        let reset = NSButton(title: "Сбросить к встроенному", target: self, action: #selector(resetImprovePromptToDefault))
        reset.bezelStyle = .rounded
        let test = NSButton(title: "Проверить на примере", target: self, action: #selector(testImprovePrompt))
        test.bezelStyle = .rounded
        let buttons = NSStackView(views: [reset, test])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        improveTestLabel = label("")
        improveTestLabel.lineBreakMode = .byWordWrapping
        improveTestLabel.maximumNumberOfLines = 2

        let scroll = makeScroll(improveText)
        scroll.heightAnchor.constraint(equalToConstant: 170).isActive = true

        section.addArrangedSubview(header)
        section.addArrangedSubview(improveEnabledCheck)
        section.addArrangedSubview(providerLabel)
        section.addArrangedSubview(improveProviderPopup)
        section.addArrangedSubview(improveProviderNote)
        section.addArrangedSubview(hint)
        section.addArrangedSubview(buttons)
        section.addArrangedSubview(scroll)
        section.addArrangedSubview(improveTestLabel)

        for view in [header, hint, scroll, improveTestLabel, improveProviderPopup, improveProviderNote] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        }
        return section
    }

    @objc private func resetImprovePromptToDefault() {
        improveText.string = DefaultPrompts.improve
    }

    @objc private func testImprovePrompt() {
        guard let provider = providers.first(where: { $0.id == improveProviderID }) else {
            improveTestLabel.stringValue = "Выберите провайдера улучшения."
            improveTestLabel.textColor = .systemOrange
            return
        }
        let prompt = improveText.string.isEmpty ? DefaultPrompts.improve : improveText.string
        improveTestLabel.stringValue = "Проверяю…"
        improveTestLabel.textColor = .secondaryLabelColor
        CorrectionTester.test(provider: provider, prompt: prompt) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let text):
                self.improveTestLabel.stringValue = "✓ \(text)"
                self.improveTestLabel.textColor = .systemGreen
            case .failure(let error):
                self.improveTestLabel.stringValue = "⚠️ \(error.localizedDescription)"
                self.improveTestLabel.textColor = .systemOrange
            }
        }
    }

    private func buildPromptSection() -> NSStackView {
        let section = NSStackView()
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 6

        let fixLabel = label("Промпт для исправления текста  (⌥Space)", bold: true)
        let fixHint = label("Используется при включённой постобработке. Пустое поле заменяется встроенным промптом.")

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
        fixScroll.heightAnchor.constraint(equalToConstant: 220).isActive = true

        section.addArrangedSubview(fixLabel)
        section.addArrangedSubview(buttons)
        section.addArrangedSubview(fixScroll)
        section.addArrangedSubview(fixHint)
        section.addArrangedSubview(promptTestLabel)

        for view in [fixLabel, fixScroll, fixHint, promptTestLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        }

        return section
    }

    private func label(_ text: String, bold: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = bold ? .boldSystemFont(ofSize: 13) : .systemFont(ofSize: 11)
        field.textColor = bold ? .labelColor : .secondaryLabelColor
        return field
    }

    private func makeScroll(_ textView: NSTextView) -> NSScrollView {
        textView.isRichText = false
        textView.allowsUndo = true
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
        let improveLabel = label("Улучшение текста")
        let note = label("Для сочетаний выше нужен хотя бы один модификатор из ⌃ / ⌥ / ⌘.")
        let enterHint = label("Во время записи Enter завершает диктовку и запускает обработку текста.")
        enterHint.font = .systemFont(ofSize: 11)
        enterHint.textColor = .secondaryLabelColor
        stopOnEnterCheck.identifier = NSUserInterfaceItemIdentifier("stop-recording-on-enter")
        cancelOnEscapeCheck.identifier = NSUserInterfaceItemIdentifier("cancel-recording-on-escape")
        let escapeHint = label("Во время записи Esc отменяет диктовку без распознавания и вставки текста.")
        escapeHint.font = .systemFont(ofSize: 11)
        escapeHint.textColor = .secondaryLabelColor

        toggleHotkeyButton = NSButton(title: toggleHotkey.display, target: self, action: #selector(captureToggle))
        toggleHotkeyButton.bezelStyle = .rounded
        improveHotkeyButton = NSButton(title: improveHotkey.display, target: self, action: #selector(captureImprove))
        improveHotkeyButton.bezelStyle = .rounded

        let views: [NSView] = [toggleLabel, improveLabel, note,
                               toggleHotkeyButton, improveHotkeyButton, stopOnEnterCheck, enterHint,
                               cancelOnEscapeCheck, escapeHint]
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

            improveLabel.topAnchor.constraint(equalTo: toggleLabel.bottomAnchor, constant: 18),
            improveLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            improveHotkeyButton.centerYAnchor.constraint(equalTo: improveLabel.centerYAnchor),
            improveHotkeyButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            improveHotkeyButton.widthAnchor.constraint(equalToConstant: 190),

            note.topAnchor.constraint(equalTo: improveLabel.bottomAnchor, constant: 22),
            note.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stopOnEnterCheck.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 22),
            stopOnEnterCheck.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stopOnEnterCheck.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            enterHint.topAnchor.constraint(equalTo: stopOnEnterCheck.bottomAnchor, constant: 6),
            enterHint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            enterHint.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            cancelOnEscapeCheck.topAnchor.constraint(equalTo: enterHint.bottomAnchor, constant: 18),
            cancelOnEscapeCheck.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            cancelOnEscapeCheck.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            escapeHint.topAnchor.constraint(equalTo: cancelOnEscapeCheck.bottomAnchor, constant: 6),
            escapeHint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            escapeHint.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
        ])

        return view
    }

    // MARK: - Горячие клавиши

    @objc private func captureToggle() { startCapture(button: toggleHotkeyButton) }
    @objc private func captureImprove() { startCapture(button: improveHotkeyButton) }

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
            button.title = (button === toggleHotkeyButton) ? toggleHotkey.display : improveHotkey.display
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
        } else {
            improveHotkey = setting
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
            let selected = [settings.dictationProvider,
                            settings.improveEnabled ? settings.improveProvider : nil]
                .compactMap { $0 }
            let usesOpenCode = selected.contains { $0.kind == .opencode }
            if !usesOpenCode {
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
        let uid = micPopup.selectedItem?.representedObject as? String ?? ""
        MicTester.test(micName: name, deviceUID: uid) { [weak self] result in
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

    @objc private func resetPromptToDefault() {
        fixText.string = DefaultPrompts.fix
    }

    @objc private func testPrompt() {
        guard let provider = providers.first(where: { $0.id == dictationProviderID }) else {
            promptTestLabel.stringValue = "Выберите провайдера для диктовки."
            promptTestLabel.textColor = .systemOrange
            return
        }
        promptTestLabel.stringValue = "Проверяю…"
        promptTestLabel.textColor = .secondaryLabelColor
        CorrectionTester.test(provider: provider, prompt: fixText.string) { [weak self] result in
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

    private func reloadMicrophones(selected: String, uid: String = "") {
        let devices = AudioInputDevice.available()
        micPopup.removeAllItems()
        for device in devices {
            micPopup.addItem(withTitle: device.name)
            micPopup.lastItem?.representedObject = device.uid
        }
        if let match = AudioInputDevice.match(name: selected, uid: uid, in: devices),
           let index = devices.firstIndex(of: match) { micPopup.selectItem(at: index) }
        else if !uid.isEmpty || !selected.isEmpty {
            // Отсутствующий выбранный input не заменяется другим устройством.
            micPopup.addItem(withTitle: selected.isEmpty ? "Микрофон недоступен" : selected)
            micPopup.lastItem?.representedObject = uid
            micPopup.selectItem(at: micPopup.numberOfItems - 1)
        } else if let device = AudioInputDevice.resolve(name: ""),
                  let index = devices.firstIndex(of: device) { micPopup.selectItem(at: index) }
        micTestButton.isEnabled = micPopup.numberOfItems > 0
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

    @objc private func changeRecognitionEngine() {
        selectedEngine = enginePopup.indexOfSelectedItem == 1 ? "nemotron" : "whisper"
    }

    @objc private func downloadFluidModel() {
        if let download = fluidDownload {
            download.stop()
            fluidDownload = nil
            refreshModels()
            return
        }
        let download = ASRProcess()
        fluidDownload = download
        fluidDownloadProgress = 0
        var completed = false
        download.onEvent = { [weak self, weak download] event in
            guard let self, let download, self.fluidDownload === download else { return }
            switch event["event"] as? String {
            case "progress":
                self.fluidDownloadProgress = max(0, min(1, event["progress"] as? Double ?? 0))
                self.fluidStatus?.stringValue = "Загрузка: \(Int(self.fluidDownloadProgress * 100))%"
            case "installed":
                completed = true
                self.fluidDownload = nil
                self.refreshModels()
            case "error":
                completed = true
                self.fluidDownload = nil
                self.refreshModels()
                self.fluidStatus?.stringValue = "Не удалось загрузить модель. Повторите попытку"
            default: break
            }
        }
        download.onExit = { [weak self] in
            guard let self, !completed else { return }
            self.fluidDownload = nil
            self.refreshModels()
            self.fluidStatus?.stringValue = "Загрузка прервана. Можно повторить"
        }
        do { try download.start(mode: "download") }
        catch {
            fluidDownload = nil
            refreshModels()
            fluidStatus?.stringValue = "Движок недоступен: \(error.localizedDescription)"
            return
        }
        refreshModels()
    }

    private func currentSettings() -> Settings {
        var settings = loadedSettings
        settings.promptFix = fixText.string
        settings.promptImprove = improveText.string
        settings.improveEnabled = improveEnabledCheck.state == .on
        settings.providers = providers
        settings.dictationProviderID = providers.contains(where: { $0.id == dictationProviderID })
            ? dictationProviderID
            : nil
        settings.improveProviderID = providers.contains(where: { $0.id == improveProviderID })
            ? improveProviderID
            : nil
        settings.language = languages[max(0, languagePopup.indexOfSelectedItem)]
        settings.microphone = micPopup.titleOfSelectedItem ?? ""
        settings.microphoneUID = micPopup.selectedItem?.representedObject as? String ?? ""
        settings.restoreClipboard = restoreCheck.state == .on
        settings.previewEnabled = previewControls.options.enabled
        settings.previewLineCount = previewControls.options.lineCount
        settings.historyEnabled = historyEnabledCheck.state == .on
        settings.historyMaxItems = max(1, min(1000, historyItemsField.integerValue))
        settings.historyMaxDays = max(1, min(3650, historyDaysField.integerValue))
        settings.hotkeyToggle = toggleHotkey
        settings.hotkeyImprove = improveHotkey
        settings.stopRecordingOnEnter = stopOnEnterCheck.state == .on
        settings.cancelRecordingOnEscape = cancelOnEscapeCheck.state == .on
        settings.whisperModelPath = selectedModelPath
        settings.whisperModelDirs = modelDirs
        settings.hiddenModelPaths = hiddenModelPaths
        settings.recognitionEngine = selectedEngine
        settings.speechVocabulary = vocabularyEditor.terms
        return settings
    }

    private func hasUnsavedChanges() -> Bool {
        currentSettings() != loadedSettings
            || (launchCheck.state == .on) != loadedLaunchAtLogin
            || providerKeys != loadedProviderKeys
            || vocabularyEditor.hasChanges
    }

    private func loadValues() {
        let settings = SettingsStore.load()
        selectedEngine = FluidModelStore.supported ? settings.recognitionEngine : "whisper"
        vocabularyEditor.load(settings.speechVocabulary)
        previewControls.options = settings.recognitionPreview
        fixText.string = settings.promptFix.isEmpty ? DefaultPrompts.fix : settings.promptFix
        promptTestLabel?.stringValue = ""
        improveTestLabel?.stringValue = ""
        micTestLabel?.stringValue = ""

        languagePopup.selectItem(at: languages.firstIndex(of: settings.language) ?? 0)
        reloadMicrophones(selected: settings.microphone, uid: settings.microphoneUID)

        providers = settings.providers
        dictationProviderID = settings.dictationProviderID
        improveProviderID = settings.improveProviderID
        providerKeys = [:]
        for provider in providers {
            providerKeys[provider.id] = provider.kind.usesAPIKey
                ? (Keychain.value(for: provider.keychainAccount) ?? "")
                : ""
        }
        loadedProviderKeys = providerKeys
        refreshProvidersList()
        refreshProviderMenus()

        restoreCheck.state = settings.restoreClipboard ? .on : .off
        refreshLaunchStatus()

        toggleHotkey = settings.hotkeyToggle
        toggleHotkeyButton.title = toggleHotkey.display
        improveHotkey = settings.hotkeyImprove
        improveHotkeyButton.title = improveHotkey.display

        improveText.string = settings.promptImprove.isEmpty ? DefaultPrompts.improve : settings.promptImprove
        stopOnEnterCheck.state = settings.stopRecordingOnEnter ? .on : .off
        cancelOnEscapeCheck.state = settings.cancelRecordingOnEscape ? .on : .off
        improveEnabledCheck.state = settings.improveEnabled ? .on : .off
        updateAIProviderState()

        modelDirs = settings.whisperModelDirs
        hiddenModelPaths = settings.hiddenModelPaths
        selectedModelPath = settings.whisperModelPath
        if selectedModelPath.isEmpty,
           let auto = WhisperModelStore.activeModel(settings: settings) {
            selectedModelPath = auto.path
        }
        refreshModels()

        historyEnabledCheck.state = settings.historyEnabled ? .on : .off
        historyItemsField.integerValue = settings.historyMaxItems
        historyItemsStepper.integerValue = settings.historyMaxItems
        historyDaysField.integerValue = settings.historyMaxDays
        historyDaysStepper.integerValue = settings.historyMaxDays
        reloadHistory()

        loadedSettings = settings
        loadedSettings.promptFix = fixText.string
        loadedSettings.promptImprove = improveText.string
        loadedSettings.improveEnabled = improveEnabledCheck.state == .on
        loadedSettings.whisperModelPath = selectedModelPath
        loadedSettings.recognitionEngine = selectedEngine
        if loadedSettings.microphone.isEmpty {
            loadedSettings.microphone = micPopup.titleOfSelectedItem ?? ""
        }
        loadedSettings.microphoneUID = micPopup.selectedItem?.representedObject as? String ?? ""
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
        case "hotkeys":
            stopOnEnterCheck.state = .off
            cancelOnEscapeCheck.state = .off
            toggleHotkey = HotKeySetting()
            toggleHotkeyButton.title = toggleHotkey.display
            improveHotkey = HotKeySetting.improveDefault
            improveHotkeyButton.title = improveHotkey.display
        case "providers":
            let provider = AIProvider.openCodeDefault()
            providers = [provider]
            providerKeys = [provider.id: ""]
            dictationProviderID = provider.id
            improveProviderID = provider.id
            refreshProvidersList()
            refreshProviderMenus()
        case "ai":
            fixText.string = DefaultPrompts.fix
            improveText.string = DefaultPrompts.improve
            improveEnabledCheck.state = .on
            promptTestLabel?.stringValue = ""
            improveTestLabel?.stringValue = ""
            updateAIProviderState()
        case "models":
            previewControls.options = RecognitionPreview()
            selectedEngine = "whisper"
            languagePopup.selectItem(at: 0)
            modelDirs = []
            hiddenModelPaths = []
            selectedModelPath = WhisperModelStore.autoSelect(
                from: WhisperModelStore.foundModels())?.path ?? ""
            refreshModels()
        case "dictionary":
            vocabularyEditor.reset()
        case "history":
            historyEnabledCheck.state = .on
            historyItemsField.integerValue = 100
            historyItemsStepper.integerValue = 100
            historyDaysField.integerValue = 30
            historyDaysStepper.integerValue = 30
            reloadHistory()
        default:
            reloadMicrophones(selected: "")
            restoreCheck.state = .off
        }
    }

    @objc private func cancel() {
        window?.performClose(nil)
    }

    @objc private func saveSettings() {
        previewControls.commit()
        guard vocabularyEditor.commit() else {
            selectTab("dictionary")
            return
        }
        let settings = currentSettings()

        if toggleHotkey.keyCode == improveHotkey.keyCode,
           toggleHotkey.modifiers == improveHotkey.modifiers {
            let alert = NSAlert()
            alert.messageText = "Сочетания совпадают"
            alert.informativeText = "Диктовка и улучшение текста должны иметь разные хоткеи."
            alert.runModal()
            return
        }

        if let error = validateProviders() {
            let alert = NSAlert()
            alert.messageText = "Проверьте провайдеров"
            alert.informativeText = error
            alert.runModal()
            selectTab("providers")
            return
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

        var normalizedKeys: [UUID: String] = [:]
        for provider in settings.providers {
            let key = provider.kind.usesAPIKey
                ? (providerKeys[provider.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            normalizedKeys[provider.id] = key
            if provider.kind.usesAPIKey, !key.isEmpty {
                Keychain.set(key, for: provider.keychainAccount)
            } else {
                Keychain.delete(account: provider.keychainAccount)
            }
        }
        let currentIDs = Set(settings.providers.map(\.id))
        for old in loadedSettings.providers where !currentIDs.contains(old.id) {
            Keychain.delete(account: old.keychainAccount)
        }
        providerKeys = normalizedKeys

        SettingsStore.save(settings)
        HistoryStore.shared.prune(maxItems: settings.historyMaxItems,
                                  maxDays: settings.historyMaxDays)
        reloadHistory()
        loadedSettings = settings
        loadedProviderKeys = normalizedKeys
        loadedLaunchAtLogin = SMAppService.mainApp.status == .enabled
        onSettingsSaved?()
        Log.write("settings saved providers=\(settings.providers.count) dictation=\(settings.dictationProvider?.displayTitle ?? "none") improve=\(settings.improveProvider?.displayTitle ?? "none")")
        allowClose = true
        window?.close()
        allowClose = false
    }

    private func validateProviders() -> String? {
        var names = Set<String>()
        for provider in providers {
            let name = provider.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let model = provider.model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return "Укажите название каждого провайдера." }
            let normalized = name.lowercased()
            guard names.insert(normalized).inserted else {
                return "Названия провайдеров не должны совпадать: «\(name)»."
            }
            guard !model.isEmpty else { return "Укажите модель для «\(name)»." }
            switch provider.kind {
            case .opencode:
                guard !provider.providerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return "Укажите provider ID OpenCode для «\(name)»."
                }
            case .openai, .anthropic:
                let base = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !base.isEmpty else {
                    return "Укажите базовый URL для «\(name)»."
                }
                do {
                    _ = try AIProviderURL.validateBase(base)
                } catch {
                    return "Провайдер «\(name)»: \(error.localizedDescription)"
                }
            }
        }
        return nil
    }
}

/// Документ NSScrollView с началом координат сверху — иначе контент
/// прижимается к нижнему краю окна.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

extension SettingsWindow: NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredHistory.count
    }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard row >= 0, row < filteredHistory.count,
              let identifier = tableColumn?.identifier.rawValue else { return nil }
        let entry = filteredHistory[row]
        let value = identifier == "date"
            ? historyDateFormatter.string(from: entry.date)
            : entry.text.replacingOccurrences(of: "\n", with: " ")
        let label = NSTextField(labelWithString: value)
        if identifier == "date" {
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
        } else {
            label.font = .systemFont(ofSize: 12)
            label.textColor = .labelColor
        }
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = historyTable?.selectedRow ?? -1
        if row >= 0, row < filteredHistory.count {
            historyDetail?.string = filteredHistory[row].text
        } else {
            historyDetail?.string = "Выберите запись в списке."
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === historySearch else { return }
        reloadHistory()
    }
}
