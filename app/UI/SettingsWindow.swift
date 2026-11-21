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
    private let summaryText = NSTextView()
    private var promptTestLabel: NSTextField!
    private var improveTestLabel: NSTextField!
    private var summaryTestLabel: NSTextField!
    private var improveEnabledCheck: NSSwitch!
    private var improveGroup: NSStackView!
    private var summaryGroup: NSStackView!
    private var sidebar: SettingsSidebar!
    private var pageScroll: NSScrollView!
    private var pageDocument: FlippedView!
    private var pageHost: NSView!
    private var pageTitleLabel: NSTextField!
    private var pageSubtitleLabel: NSTextField!
    private var footer: SettingsFooter!
    private var pages: [String: NSView] = [:]
    private var currentTab = "general"
    private var languagePopup: NSPopUpButton!
    private var micPopup: NSPopUpButton!
    private var micTestButton: NSButton!
    private var micTestLabel: NSTextField!
    private var micTestRow: NSView?
    private var samplePanel: AudioSamplePanel?
    var hasActiveOperations: Bool { !downloads.isEmpty || fluidDownload != nil || samplePanel?.isBusy == true }
    private let updateStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let storageCacheLabel = SettingsText.rowTitle("—")
    private let storageModelsLabel = SettingsText.rowTitle("—")
    private let storageHistoryLabel = SettingsText.rowTitle("—")
    private let storageTotalLabel = SettingsText.rowTitle("—")
    private let storageStatus = SettingsText.footnote("")
    private lazy var storageStatusRow: NSView = {
        let content = SettingsContentRow(storageStatus, verticalInset: 8)
        let stack = NSStackView(views: [SettingsSeparatorView(), content])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
        stack.isHidden = true
        return stack
    }()
    private lazy var clearCacheButton = storageIconButton("trash", "Удалить временные файлы", #selector(clearCache))
    private lazy var openModelsButton = storageIconButton("chevron.right", "Открыть раздел моделей", #selector(openModelsSection))
    private lazy var openHistoryButton = storageIconButton("chevron.right", "Открыть раздел истории", #selector(openHistorySection))
    private var storageUsage: SettingsStorage.Usage?
    private var storageRequest: UUID?
    private var lastStorageRefresh = Date.distantPast
    private var storageSection: NSView?

    private var launchCheck: NSSwitch!
    private var launchNote: NSTextField!
    private var dictationProviderPopup: NSPopUpButton!
    private var improveProviderPopup: NSPopUpButton!
    private var dictationProviderNote: NSTextField!
    private var improveProviderNote: NSTextField!
    private var providersGrid: SettingsDataTable!
    private var markedProviders: Set<UUID> = []
    private lazy var removeProvidersButton = SettingsDataTable.iconButton(
        "minus", "Удалить выбранных провайдеров", target: self, action: #selector(deleteMarkedProviders))
    private var providerEditor: ProviderEditorWindow?
    private var providers: [AIProvider] = []
    private var providerKeys: [UUID: String] = [:]
    private var loadedProviderKeys: [UUID: String] = [:]
    private var dictationProviderID: UUID?
    private var improveProviderID: UUID?
    private var promptGroup: NSStackView!
    private var restoreCheck: NSSwitch!
    private var versionLabel: NSTextField!
    private let apiEnable = NSSwitch()
    private let apiFilter = NSSwitch()
    private let apiVocabulary = NSSwitch()
    private let apiThreshold = NSSlider(value: -55, minValue: -70, maxValue: -20, target: nil, action: nil)
    private let apiThresholdLabel = NSTextField(labelWithString: "")
    var onAPISettingsSaved: (() -> Void)?
    private let apiImprove = NSSwitch()
    private let apiPortField = NSTextField(string: "8790")
    private let apiAddress = NSTextField(labelWithString: "")
    private let apiStatus = NSTextField(wrappingLabelWithString: "")
    private let apiActivity = NSProgressIndicator()
    private lazy var apiCopyAddressButton = SettingsText.linkButton("Копировать", target: self, action: #selector(copyAPIAddress))
    private lazy var apiCheckButton = SettingsText.secondaryButton("Проверить соединение", target: self, action: #selector(checkAPIConnection))
    private lazy var apiRestartButton = SettingsText.secondaryButton("Перезапустить сервер", target: self, action: #selector(restartAPI))
    private var apiCheckTask: URLSessionDataTask?
    private var apiCheckToken: UUID?
    private var apiCheckedConnection: UUID?
    private var apiCheckResult: LocalAPIService.ConnectionCheck?
    private var apiCheckStatus: String?
    private let apiModel = NSTextField(wrappingLabelWithString: "")
    private let apiModelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var selectedAPIModel: APIRecognitionModel = .application
    private var apiModelChoices: [APIRecognitionModel.Choice] = []
    private let apiProfile = NSTextField(wrappingLabelWithString: "")
    private var toggleHotkeyButton: NSButton!
    private var improveHotkeyButton: NSButton!
    private let stopOnEnterCheck = NSSwitch()
    private let cancelOnEscapeCheck = NSSwitch()
    private let pauseOnSpaceCheck = NSSwitch()
    private var accessLabel: NSTextField!
    private var accessButton: NSButton!
    private var modelsStack: NSStackView!
    private var modelDirs: [String] = []
    private var externalModelPaths: [String] = []
    private var hiddenModelPaths: [String] = []
    private var selectedModelPath = ""
    private var selectedTechnology: RecognitionTechnology = .whisper
    private var selectedFluidModel: FluidModel = .nemotron
    private let technologyPopup = NSPopUpButton()
    private var recognitionValidationMessage = ""
    private let vocabularyEditor = SpeechVocabularyEditor()
    private let previewControls = RecognitionPreviewControls()
    private var fluidDownload: ASRProcess?
    private var fluidDownloadProgress: Double = 0
    private var downloadingFluidModel: FluidModel?
    private var fluidStatuses: [FluidModel: NSTextField] = [:]
    private var fluidBars: [FluidModel: NSProgressIndicator] = [:]
    private var downloadErrors: [String: String] = [:]
    var canRemoveModel: () -> Bool = { true }
    var onModelRemoved: (() -> Void)?
    private var fluidErrors: [FluidModel: String] = [:]
    private var historyTable: NSTableView!
    private var historyGrid: SettingsDataTable!
    private lazy var clearHistoryButton = SettingsText.destructiveButton(
        "Очистить историю…", target: self, action: #selector(clearHistory))
    private var historyRecordCount = 0
    private var historyDetail: NSTextView!
    private var historyDetailSection: NSView?
    private var historySearch: NSSearchField!
    private var historyEnabledCheck: NSSwitch!
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 780),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.contentMinSize = NSSize(width: 1020, height: 680)
        window.minSize = NSSize(width: 1020, height: 680)
        window.title = "Runvoice — Настройки"
        window.backgroundColor = SettingsStyle.pageBackground
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
        setStorageStatus("")
        refreshStorage(force: true)
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self, self.window?.isVisible == true else { timer.invalidate(); return }
            self.refreshDiagnostics(force: false)
            self.refreshStorage()
            self.updateDirtyState()
        }
        let current = window?.contentView?.bounds.size ?? NSSize(width: 1160, height: 780)
        window?.setContentSize(NSSize(width: max(1020, current.width),
                                      height: max(680, current.height)))
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        stopCapture()
        samplePanel?.dismiss()
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
        guard let page = pages[identifier] else { return }
        currentTab = identifier
        let meta = pageMeta(identifier)
        pageTitleLabel?.stringValue = meta.title
        pageSubtitleLabel?.stringValue = meta.subtitle
        sidebar?.select(identifier)

        pageHost?.subviews.forEach { $0.removeFromSuperview() }
        page.translatesAutoresizingMaskIntoConstraints = false
        pageHost?.addSubview(page)
        if let pageHost {
            NSLayoutConstraint.activate([
                page.topAnchor.constraint(equalTo: pageHost.topAnchor),
                page.leadingAnchor.constraint(equalTo: pageHost.leadingAnchor),
                page.trailingAnchor.constraint(equalTo: pageHost.trailingAnchor),
                page.bottomAnchor.constraint(equalTo: pageHost.bottomAnchor)
            ])
        }
        if identifier == "api" { refreshAPI() }
        if identifier == "general" { refreshStorage(force: true) }
        pageScroll?.contentView.scroll(to: .zero)
        updateDirtyState()
        window?.contentView?.needsLayout = true
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    private func pageMeta(_ identifier: String) -> (title: String, subtitle: String) {
        switch identifier {
        case "general":
            return ("Основные", "Микрофон, вставка и запуск приложения")
        case "hotkeys":
            return ("Хоткеи", "Сочетания клавиш и поведение во время записи")
        case "models":
            return ("Распознавание", "Движок, язык и модели распознавания")
        case "dictionary":
            return ("Словарь", "Технические термины для распознавания и AI-правки")
        case "providers":
            return ("Провайдеры", "Подключения и модели AI-провайдеров")
        case "ai":
            return ("Постобработка", "Промпты и провайдеры для правки текста")
        case "history":
            return ("История", "Сохранённые расшифровки и лимиты хранения")
        case "api":
            return ("API", "Локальный сервис распознавания для внешних приложений")
        default:
            return ("Настройки", "")
        }
    }

    /// Только демонстрационный снимок: настройки на диске не изменяются.
    func prepareDictionarySnapshot() {
        vocabularyEditor.load(["Cypress", "Playwright", "GitHub Actions"])
        loadedSettings.speechVocabulary = vocabularyEditor.terms
        updateDirtyState()
    }

    /// Для отладочного скриншота: показать блок улучшения текста в разделе «Постобработка».
    func scrollAIToImprove() {
        scrollToSection(improveGroup)
    }

    func scrollAIToSummary() {
        scrollToSection(summaryGroup)
    }

    func scrollToStorage() { scrollToSection(storageSection) }

    func scrollToHistoryDetail() { scrollToSection(historyDetailSection) }

    private func scrollToSection(_ group: NSView?) {
        guard let group, let document = pageDocument else { return }
        let rect = group.convert(group.bounds, to: document)
        let maxY = max(0, document.bounds.height - pageScroll.contentView.bounds.height)
        let y = min(max(0, rect.minY - 24), maxY)
        pageScroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        pageScroll.reflectScrolledClipView(pageScroll.contentView)
    }

    private func build() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true

        sidebar = SettingsSidebar()
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.onSelect = { [weak self] id in self?.selectTab(id) }
        content.addSubview(sidebar)

        let contentArea = NSView()
        contentArea.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(contentArea)

        let headerHost = NSView()
        headerHost.translatesAutoresizingMaskIntoConstraints = false
        contentArea.addSubview(headerHost)

        pageTitleLabel = SettingsText.pageTitle("")
        pageTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        headerHost.addSubview(pageTitleLabel)

        pageSubtitleLabel = SettingsText.pageSubtitle("")
        pageSubtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        headerHost.addSubview(pageSubtitleLabel)

        pageScroll = NSScrollView()
        pageScroll.hasVerticalScroller = true
        pageScroll.autohidesScrollers = true
        pageScroll.drawsBackground = false
        pageScroll.borderType = .noBorder
        pageScroll.translatesAutoresizingMaskIntoConstraints = false
        contentArea.addSubview(pageScroll)

        pageDocument = FlippedView()
        pageDocument.translatesAutoresizingMaskIntoConstraints = false
        pageHost = NSView()
        pageHost.translatesAutoresizingMaskIntoConstraints = false
        pageDocument.addSubview(pageHost)
        pageScroll.documentView = pageDocument
        let hostWidth = pageHost.widthAnchor.constraint(equalTo: pageDocument.widthAnchor,
                                                        constant: -2 * SettingsStyle.pageInset)
        hostWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            pageDocument.widthAnchor.constraint(equalTo: pageScroll.contentView.widthAnchor),
            pageHost.topAnchor.constraint(equalTo: pageDocument.topAnchor, constant: 8),
            pageHost.bottomAnchor.constraint(equalTo: pageDocument.bottomAnchor, constant: -24),
            pageHost.centerXAnchor.constraint(equalTo: pageDocument.centerXAnchor),
            pageHost.leadingAnchor.constraint(greaterThanOrEqualTo: pageDocument.leadingAnchor,
                                              constant: SettingsStyle.pageInset),
            pageHost.trailingAnchor.constraint(lessThanOrEqualTo: pageDocument.trailingAnchor,
                                              constant: -SettingsStyle.pageInset),
            pageHost.widthAnchor.constraint(lessThanOrEqualToConstant: SettingsStyle.contentMaxWidth),
            hostWidth
        ])

        footer = SettingsFooter()
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.resetButton.target = self
        footer.resetButton.action = #selector(resetDefaults)
        footer.cancelButton.target = self
        footer.cancelButton.action = #selector(cancel)
        footer.saveButton.target = self
        footer.saveButton.action = #selector(saveSettings)
        contentArea.addSubview(footer)

        let hiddenVersion = SampleAccessLabel(labelWithString: "")
        hiddenVersion.onOpen = { [weak self] in self?.showAudioSamples() }
        hiddenVersion.identifier = NSUserInterfaceItemIdentifier("settings-version")
        versionLabel = hiddenVersion
        versionLabel.font = .systemFont(ofSize: 10)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(versionLabel)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        versionLabel.stringValue = (build.isEmpty || build == version) ? "v\(version)" : "v\(version) (\(build))"

        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: SettingsStyle.sidebarWidth),

            contentArea.topAnchor.constraint(equalTo: content.topAnchor),
            contentArea.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            contentArea.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            contentArea.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            headerHost.topAnchor.constraint(equalTo: contentArea.topAnchor, constant: 22),
            headerHost.centerXAnchor.constraint(equalTo: contentArea.centerXAnchor),
            headerHost.widthAnchor.constraint(equalTo: pageHost.widthAnchor),

            pageTitleLabel.topAnchor.constraint(equalTo: headerHost.topAnchor),
            pageTitleLabel.leadingAnchor.constraint(equalTo: headerHost.leadingAnchor),
            pageTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: headerHost.trailingAnchor),

            pageSubtitleLabel.topAnchor.constraint(equalTo: pageTitleLabel.bottomAnchor, constant: 3),
            pageSubtitleLabel.leadingAnchor.constraint(equalTo: pageTitleLabel.leadingAnchor),
            pageSubtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: headerHost.trailingAnchor),
            pageSubtitleLabel.bottomAnchor.constraint(equalTo: headerHost.bottomAnchor),

            pageScroll.topAnchor.constraint(equalTo: pageSubtitleLabel.bottomAnchor, constant: 10),
            pageScroll.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            pageScroll.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
            pageScroll.bottomAnchor.constraint(equalTo: footer.topAnchor),

            footer.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 52),

            versionLabel.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 18),
            versionLabel.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -12)
        ])

        pages["general"] = buildGeneral()
        pages["models"] = buildModels()
        pages["dictionary"] = buildDictionaryPage()
        pages["providers"] = buildProviders()
        pages["ai"] = buildAI()
        pages["history"] = buildHistory()
        pages["hotkeys"] = buildHotkeys()
        pages["api"] = buildAPI()

        selectTab("general")
    }

    private func buildDictionaryPage() -> NSView {
        let container = NSView()
        vocabularyEditor.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(vocabularyEditor)
        NSLayoutConstraint.activate([
            vocabularyEditor.topAnchor.constraint(equalTo: container.topAnchor),
            vocabularyEditor.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            vocabularyEditor.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            vocabularyEditor.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    private func updateDirtyState() {
        guard footer != nil else { return }
        footer.dirtyLabel.isHidden = !hasUnsavedChanges()
    }


    // MARK: - General

    private func buildGeneral() -> NSView {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = SettingsStyle.sectionSpacing

        micPopup = NSPopUpButton()
        micPopup.widthAnchor.constraint(equalToConstant: 240).isActive = true
        micTestButton = SettingsText.secondaryButton("Проверить", target: self, action: #selector(testMicrophone))
        micTestLabel = SettingsText.footnote("")
        micTestLabel.lineBreakMode = .byTruncatingTail
        micTestLabel.isHidden = true

        let micCard = SettingsCard()
        micCard.addRow(SettingsRow(title: "Микрофон",
                                   subtitle: "Устройство, с которого записывается диктовка.",
                                   trailing: [micPopup, micTestButton],
                                   subtitleWidth: 290))
        let micTestRow = SettingsContentRow(micTestLabel, verticalInset: 6)
        micTestRow.isHidden = micTestLabel.stringValue.isEmpty
        self.micTestRow = micTestRow
        micCard.addRow(micTestRow)

        restoreCheck = NSSwitch()
        restoreCheck.identifier = NSUserInterfaceItemIdentifier("restore-clipboard")
        let insertCard = SettingsCard()
        insertCard.addRow(SettingsRow(title: "Восстанавливать буфер обмена",
                                      subtitle: "Возвращать прежнее содержимое после вставки текста.",
                                      trailing: [restoreCheck]))

        launchCheck = NSSwitch()
        launchCheck.identifier = NSUserInterfaceItemIdentifier("launch-at-login")
        launchNote = SettingsText.footnote("")
        launchNote.textColor = .systemOrange
        launchNote.isHidden = true
        let launchCard = SettingsCard()
        launchCard.addRow(SettingsRow(title: "Запускать при входе",
                                      subtitle: "Runvoice будет доступен сразу после входа в систему.",
                                      subtitleView: launchNote,
                                      trailing: [launchCheck]))

        accessLabel = SettingsText.rowSubtitle("", width: 130)
        accessLabel.alignment = .right
        accessButton = SettingsText.secondaryButton("Открыть настройки",
                                                    target: self,
                                                    action: #selector(openAccessibility))
        depStack = NSStackView()
        depStack.orientation = .vertical
        depStack.alignment = .leading
        depStack.spacing = 4
        depLabels = Dependency.diagnosticsCases.map { _ in
            let field = SettingsText.footnote("")
            field.lineBreakMode = .byTruncatingMiddle
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return field
        }
        for depLabel in depLabels {
            depLabel.translatesAutoresizingMaskIntoConstraints = false
            depStack.addArrangedSubview(depLabel)
            depLabel.widthAnchor.constraint(equalTo: depStack.widthAnchor).isActive = true
        }
        let accessCard = SettingsCard()
        accessCard.addRow(SettingsRow(title: "Accessibility",
                                      subtitle: "Нужен для вставки текста в другие приложения.",
                                      trailing: [accessLabel, accessButton]))
        accessCard.addRow(SettingsContentRow(depStack, verticalInset: 12))
        let logRow = SettingsRow(title: "Лог и данные",
                                 subtitle: "Файлы состояния и журнал работы Runvoice.",
                                 trailing: [
                                    SettingsText.linkButton("Открыть лог", target: self, action: #selector(openLog)),
                                    SettingsText.linkButton("Папка данных", target: self, action: #selector(openData))
                                 ])
        accessCard.addRow(logRow)

        let updateButton = SettingsText.secondaryButton("Проверить обновления…",
                                                        target: self,
                                                        action: #selector(checkUpdates))
        updateButton.identifier = NSUserInterfaceItemIdentifier("check-updates")
        updateStatusLabel.font = .systemFont(ofSize: 11.5)
        updateStatusLabel.textColor = .secondaryLabelColor
        updateStatusLabel.maximumNumberOfLines = 0
        updateStatusLabel.preferredMaxLayoutWidth = 430
        let updateCard = SettingsCard()
        updateCard.addRow(SettingsRow(title: "Обновления Runvoice",
                                      subtitleView: updateStatusLabel,
                                      trailing: [updateButton]))

        root.addArrangedFullWidth(SettingsSection(title: "Ввод", card: micCard))
        root.addArrangedFullWidth(SettingsSection(title: "Вставка", card: insertCard))
        root.addArrangedFullWidth(SettingsSection(title: "Запуск", card: launchCard))
        root.addArrangedFullWidth(SettingsSection(title: "Разрешения и диагностика", card: accessCard))
        let storage = buildStorageSection()
        storageSection = storage
        root.addArrangedFullWidth(storage)
        root.addArrangedFullWidth(SettingsSection(title: "Обновления", card: updateCard))
        return root
    }

    private func buildStorageSection() -> SettingsSection {
        let card = SettingsCard()
        for label in [storageCacheLabel, storageModelsLabel, storageHistoryLabel, storageTotalLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 13, weight: label === storageTotalLabel ? .semibold : .regular)
        }
        card.addRow(SettingsRow(title: "Кеш приложения", subtitle: "Временные файлы, которые Runvoice может создать снова.",
                                 trailing: [storageCacheLabel, clearCacheButton]))
        card.addRow(SettingsRow(title: "Скачанные модели", subtitle: "Модели Whisper и FluidAudio в хранилище Runvoice.",
                                 trailing: [storageModelsLabel, openModelsButton]))
        card.addRow(SettingsRow(title: "История распознаваний", subtitle: "Сохранённые расшифровки на этом Mac.",
                                 trailing: [storageHistoryLabel, openHistoryButton]))
        let totalSlot = NSView()
        totalSlot.widthAnchor.constraint(equalToConstant: 24).isActive = true
        card.addRow(SettingsRow(title: "Всего", trailing: [storageTotalLabel, totalSlot], verticalInset: 8))
        card.addRow(storageStatusRow, separated: false)
        updateStorageActions()
        return SettingsSection(title: "Память", note: "Место на диске, которое занимают кеш, скачанные модели и история Runvoice.", card: card)
    }

    private var canClearStorage: Bool {
        canRemoveModel() && !hasActiveOperations && !MicTester.isBusy && !UpdateCoordinator.shared.isInstalling
    }

    private func updateStorageActions() {
        let available = canClearStorage && storageRequest == nil
        let cacheIsEmpty = storageUsage?.cache == 0
        clearCacheButton.isEnabled = available && (storageUsage?.cache ?? 0) > 0
        if !canClearStorage {
            clearCacheButton.toolTip = "Дождитесь завершения распознавания, загрузки или обновления."
        } else if cacheIsEmpty {
            clearCacheButton.toolTip = "Кеш пуст"
        } else {
            clearCacheButton.toolTip = "Удалить временные файлы"
        }
    }

    private func refreshStorage(force: Bool = false) {
        guard currentTab == "general" else { return }
        updateStorageActions()
        guard force || (storageRequest == nil && Date().timeIntervalSince(lastStorageRefresh) >= 5) else { return }
        let token = UUID()
        storageRequest = token
        lastStorageRefresh = Date()
        updateStorageActions()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let usage = SettingsStorage.measure()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.storageRequest == token else { return }
                self.storageRequest = nil
                self.storageUsage = usage
                self.storageCacheLabel.stringValue = Self.storageSize(usage.cache)
                self.storageModelsLabel.stringValue = Self.storageSize(usage.models)
                self.storageHistoryLabel.stringValue = Self.storageSize(usage.history)
                self.storageTotalLabel.stringValue = Self.storageSize(usage.total)
                let measurementError = "Не удалось подсчитать размер полностью"
                if usage.total == nil {
                    if self.storageStatus.stringValue.isEmpty { self.setStorageStatus(measurementError) }
                } else if self.storageStatus.stringValue == measurementError {
                    self.setStorageStatus("")
                }
                self.updateStorageActions()
            }
        }
    }

    private static func storageSize(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        return bytes == 0 ? "0 МБ" : WhisperSize.text(bytes)
    }

    private func storageIconButton(_ symbol: String, _ title: String, _ action: Selector) -> NSButton {
        let button = SettingsIconButton(title: "", target: self, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .light))
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        return button
    }

    private func setStorageStatus(_ text: String) {
        storageStatus.stringValue = text
        storageStatusRow.isHidden = text.isEmpty
    }

    @objc private func clearCache() { clearStorage() }

    @objc private func openModelsSection() { selectTab("models") }

    @objc private func openHistorySection() { selectTab("history") }

    private func clearStorage() {
        guard canClearStorage else {
            setStorageStatus("Дождитесь завершения распознавания, загрузки или обновления.")
            updateStorageActions()
            return
        }
        if let error = SettingsStorage.clearCache() {
            setStorageStatus("Не удалось очистить всё. \(error.localizedDescription)")
        } else {
            setStorageStatus("Кеш очищен")
        }
        refreshStorage(force: true)
    }

    @objc private func checkUpdates() { UpdateCoordinator.shared.check() }

    private func buildAPI() -> NSView {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = SettingsStyle.sectionSpacing

        apiEnable.identifier = NSUserInterfaceItemIdentifier("api-enabled")
        apiImprove.identifier = NSUserInterfaceItemIdentifier("api-improve-text")
        apiPortField.identifier = NSUserInterfaceItemIdentifier("api-port")
        apiModelPopup.identifier = NSUserInterfaceItemIdentifier("api-recognition-model")
        apiModelPopup.autoenablesItems = false
        apiModelPopup.target = self
        apiModelPopup.action = #selector(apiModelChanged)
        apiModelPopup.cell?.lineBreakMode = .byTruncatingTail
        apiModelPopup.widthAnchor.constraint(lessThanOrEqualToConstant: 380).isActive = true

        apiEnable.target = self; apiEnable.action = #selector(refreshAPI)
        apiImprove.target = self; apiImprove.action = #selector(refreshAPI)
        apiPortField.target = self; apiPortField.action = #selector(refreshAPI)
        apiPortField.delegate = self
        apiPortField.widthAnchor.constraint(equalToConstant: 80).isActive = true

        apiAddress.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        apiAddress.textColor = .secondaryLabelColor
        apiAddress.isSelectable = true
        apiAddress.lineBreakMode = .byTruncatingMiddle
        apiAddress.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        apiCopyAddressButton.setAccessibilityLabel("Копировать адрес API")
        let alias = NSTextField(labelWithString: LocalAPIWire.modelAlias)
        alias.font = apiAddress.font
        alias.textColor = .secondaryLabelColor
        alias.isSelectable = true
        let copyAlias = SettingsText.linkButton("Копировать", target: self, action: #selector(copyAPIModelAlias))
        copyAlias.setAccessibilityLabel("Копировать модель распознавания API")

        apiStatus.font = .systemFont(ofSize: 11.5)
        apiStatus.maximumNumberOfLines = 0
        apiStatus.preferredMaxLayoutWidth = 260
        apiStatus.textColor = .secondaryLabelColor
        apiActivity.style = .spinning
        apiActivity.controlSize = .small
        apiActivity.isHidden = true
        apiActivity.widthAnchor.constraint(equalToConstant: 12).isActive = true
        apiActivity.heightAnchor.constraint(equalToConstant: 12).isActive = true
        let apiStatusLine = NSStackView(views: [apiActivity, apiStatus])
        apiStatusLine.orientation = .horizontal
        apiStatusLine.alignment = .centerY
        apiStatusLine.spacing = 5
        for button in [apiCheckButton, apiRestartButton] {
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        apiModel.font = .systemFont(ofSize: 11.5)
        apiModel.textColor = .secondaryLabelColor
        apiModel.maximumNumberOfLines = 0
        apiModel.preferredMaxLayoutWidth = 430
        apiProfile.font = .systemFont(ofSize: 11.5)
        apiProfile.textColor = .secondaryLabelColor
        apiProfile.maximumNumberOfLines = 0
        apiProfile.preferredMaxLayoutWidth = 430

        let serviceCard = SettingsCard()
        serviceCard.addRow(SettingsRow(title: "Включить локальный API",
                                       subtitle: "Работает вместе с Runvoice. Язык и словарь общие, модель можно выбрать отдельно.",
                                       trailing: [apiEnable]))
        serviceCard.addRow(SettingsRow(title: "Порт", trailing: [apiPortField]))
        serviceCard.addRow(SettingsRow(title: "Адрес", subtitleView: apiAddress, trailing: [apiCopyAddressButton]))
        serviceCard.addRow(SettingsRow(title: "Модель распознавания", subtitleView: alias, trailing: [copyAlias]))
        serviceCard.addRow(SettingsRow(title: "Текущая модель", subtitleView: apiModel))
        serviceCard.addRow(SettingsRow(title: "Использовать для распознавания", trailing: [apiModelPopup]))
        serviceCard.addRow(SettingsRow(title: "Состояние", subtitleView: apiStatusLine,
                                       trailing: [apiCheckButton, apiRestartButton], subtitleWidth: 278))
        let contract = SettingsText.footnote("Для ktalk-assist: способ «Свой сервис», модель \(LocalAPIWire.modelAlias), ключ пустой. Сервер доступен только на 127.0.0.1. Изменения применяются после сохранения.")

        apiFilter.identifier = NSUserInterfaceItemIdentifier("api-audio-filter")
        apiVocabulary.identifier = NSUserInterfaceItemIdentifier("api-use-vocabulary")
        apiThreshold.identifier = NSUserInterfaceItemIdentifier("api-minimum-dbfs")
        apiThreshold.numberOfTickMarks = 0
        apiThreshold.allowsTickMarkValuesOnly = false
        apiThreshold.widthAnchor.constraint(equalToConstant: 200).isActive = true
        apiThresholdLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        apiThresholdLabel.textColor = .secondaryLabelColor
        for control in [apiFilter as NSControl, apiVocabulary, apiThreshold] {
            control.target = self
            control.action = #selector(refreshAPI)
        }

        let audioCard = SettingsCard()
        audioCard.addRow(SettingsRow(title: "Фильтровать слабый сигнал и неречевые звуки",
                                     subtitle: "Звук ниже порога не отправляется в распознавание.",
                                     trailing: [apiFilter]))
        audioCard.addRow(SettingsRow(title: "Минимальная громкость",
                                     trailing: [apiThreshold, apiThresholdLabel]))
        audioCard.addRow(SettingsRow(title: "Использовать словарь",
                                     subtitle: "Словарь применяется к распознаванию и AI-правке.",
                                     trailing: [apiVocabulary]))
        let filterHint = SettingsText.footnote("Ближе к нулю — строже фильтрация. Влияет только на аудио API.")

        let aiCard = SettingsCard()
        aiCard.addRow(SettingsRow(title: "Улучшать текст через AI",
                                  subtitle: "Используется профиль и промпт правки диктовки.",
                                  trailing: [apiImprove]))
        aiCard.addRow(SettingsRow(title: "Профиль", subtitleView: apiProfile))
        let privacy = SettingsText.footnote("AI выключен по умолчанию. API не вставляет текст и не добавляет записи в историю.")

        root.addArrangedFullWidth(sectionWithFootnote(SettingsSection(title: "Сервис", card: serviceCard), contract))
        root.addArrangedFullWidth(sectionWithFootnote(SettingsSection(title: "Обработка звука", card: audioCard), filterHint))
        root.addArrangedFullWidth(sectionWithFootnote(SettingsSection(title: "AI-правка", card: aiCard), privacy))
        return root
    }

    private func sectionWithFootnote(_ section: NSView, _ footnote: NSView) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.addArrangedFullWidth(section)
        stack.addArrangedFullWidth(footnote)
        return stack
    }

    @objc private func refreshAPI() {
        apiThreshold.isEnabled = apiFilter.state == .on
        apiThresholdLabel.stringValue = "\(Int(apiThreshold.doubleValue.rounded())) dBFS"
        var draft = loadedSettings
        draft.whisperModelPath = selectedModelPath
        draft.whisperModelDirs = modelDirs
        draft.whisperExternalModelPaths = externalModelPaths
        draft.hiddenModelPaths = hiddenModelPaths
        refreshAPIModels(settings: draft)
        let validPort = LocalAPIService.validPort(apiDraftPort)
        setLabel(apiAddress, validPort ? LocalAPIService.endpoint(port: apiDraftPort) : "Укажите корректный порт")
        apiAddress.textColor = validPort ? .secondaryLabelColor : .systemOrange
        apiCopyAddressButton.isEnabled = validPort
        let settings = SettingsStore.load()
        refreshAPIStatus(settings: settings)
        let effective = settings.apiRecognitionSettings
        setLabel(apiModel, LocalAPIService.shared.loadedModelDescription.map { "Загружено: " + $0 }
            ?? ("Сохранено: " + effective.recognitionTechnology.title + " · " + LocalAPIService.modelName(settings)))
        let selected = providers.first { $0.id == dictationProviderID }
        setLabel(apiProfile, selected.map { "AI: " + $0.displayTitle + " · " + $0.detail }
            ?? "Для AI выберите профиль правки диктовки в разделе «Постобработка».")
        apiProfile.textColor = apiImprove.state == .on && selected == nil ? .systemOrange : .secondaryLabelColor
    }

    private var apiDraftPort: Int {
        Int(apiPortField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private func resetAPICheck() {
        apiCheckTask?.cancel()
        apiCheckTask = nil
        apiCheckToken = nil
        apiCheckedConnection = nil
        apiCheckResult = nil
        apiCheckStatus = nil
    }

    private func refreshAPIStatus(settings: Settings) {
        let service = LocalAPIService.shared
        let changedPort = apiDraftPort != settings.apiPort
        let changedToggle = (apiEnable.state == .on) != settings.apiEnabled
        if changedPort || changedToggle || !settings.apiEnabled || apiCheckedConnection != service.connectionID {
            resetAPICheck()
        }
        let canAct = settings.apiEnabled && LocalAPIService.validPort(settings.apiPort)
            && !changedPort && !changedToggle && apiCheckToken == nil
            && !service.isRestarting && !service.isStarting && !UpdateCoordinator.shared.isInstalling
        apiCheckButton.isEnabled = canAct
        apiRestartButton.isEnabled = canAct && !service.isWarming

        var message = service.status
        var isError = message.hasPrefix("Ошибка")
        if apiCheckResult?.isError == true, apiCheckStatus != message { resetAPICheck() }
        if changedPort || changedToggle {
            message = changedToggle ? "Сохраните настройки API для проверки или перезапуска"
                : "Сохраните изменения порта для проверки или перезапуска"
            isError = false
        } else if apiCheckToken != nil {
            message += " · Проверяется соединение…"
        } else if let result = apiCheckResult {
            switch result {
            case .ready:
                if !isError { message += " · " + result.message }
            case .warming:
                if !isError && message != "Готов" { message = result.message }
            default:
                message += "\n" + result.message
                isError = result.isError
            }
        }
        let showActivity = apiCheckToken != nil || service.isRestarting
        if showActivity != !apiActivity.isHidden {
            apiActivity.isHidden = !showActivity
            if showActivity { apiActivity.startAnimation(nil) } else { apiActivity.stopAnimation(nil) }
        }
        setLabel(apiStatus, message)
        apiStatus.textColor = isError ? .systemOrange : .secondaryLabelColor
    }

    @objc private func checkAPIConnection() {
        refreshAPI()
        guard apiCheckButton.isEnabled else { return }
        let service = LocalAPIService.shared
        let token = UUID()
        apiCheckToken = token
        apiCheckedConnection = service.connectionID
        apiCheckResult = nil
        apiCheckTask = service.checkConnection { [weak self] result in
            guard let self, self.apiCheckToken == token else { return }
            self.apiCheckTask = nil
            self.apiCheckToken = nil
            self.apiCheckResult = result
            self.apiCheckStatus = service.status
            self.refreshAPI()
        }
        refreshAPI()
    }

    @objc private func restartAPI() {
        refreshAPI()
        guard apiRestartButton.isEnabled else { return }
        resetAPICheck()
        LocalAPIService.shared.restart()
        refreshAPI()
    }

    private func setLabel(_ field: NSTextField, _ text: String) {
        guard field.stringValue != text else { return }
        field.stringValue = text
        field.invalidateIntrinsicContentSize()
        field.superview?.invalidateIntrinsicContentSize()
        field.superview?.superview?.needsLayout = true
    }

    private func refreshAPIModels(settings: Settings) {
        var choices = APIRecognitionModel.choices(settings: settings)
        let unavailable = !choices.contains { $0.model == selectedAPIModel }
        if unavailable {
            choices.append(.init(model: selectedAPIModel, title: "Недоступна: " + selectedAPIModel.title))
        }
        if choices != apiModelChoices {
            apiModelChoices = choices
            apiModelPopup.removeAllItems()
            for choice in choices {
                apiModelPopup.addItem(withTitle: choice.title)
                apiModelPopup.lastItem?.isEnabled = !(unavailable && choice.model == selectedAPIModel)
            }
        }
        apiModelPopup.selectItem(at: choices.firstIndex { $0.model == selectedAPIModel } ?? 0)
    }

    @objc private func apiModelChanged() {
        let index = apiModelPopup.indexOfSelectedItem
        guard apiModelChoices.indices.contains(index) else { return }
        selectedAPIModel = apiModelChoices[index].model
        refreshAPI()
    }

    @objc private func copyAPIAddress() {
        refreshAPI()
        guard LocalAPIService.validPort(apiDraftPort) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(apiAddress.stringValue, forType: .string)
    }

    @objc private func copyAPIModelAlias() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(LocalAPIWire.modelAlias, forType: .string)
    }

    // MARK: - Providers

    private func buildProviders() -> NSView {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = SettingsStyle.sectionSpacing

        let add = SettingsDataTable.iconButton("plus", "Добавить провайдера…", target: self, action: #selector(addProvider))
        providersGrid = SettingsDataTable("AI-провайдеры", columns: [
            .init(id: "mark", title: "", width: 36, fixed: true),
            .init(id: "name", title: "Профиль", width: 286),
            .init(id: "type", title: "Тип", width: 125, fixed: true),
            .init(id: "model", title: "Модель", width: 165, fixed: true),
            .init(id: "actions", title: "", width: 60, fixed: true)
        ], height: 190, actions: [add, removeProvidersButton], empty: "Провайдеры не добавлены")
        root.addArrangedFullWidth(SettingsSection(title: "AI-провайдеры",
                                                  note: "Используемые профили защищены. Профиль и связанный ключ удаляются после сохранения настроек.",
                                                  card: providersGrid))
        refreshProvidersList()
        return root
    }

    private func providerIsProtected(_ id: UUID) -> Bool {
        id == dictationProviderID || id == improveProviderID
    }

    private func providerCells(_ provider: AIProvider) -> [NSView] {
        let check = NSButton(checkboxWithTitle: "", target: self, action: #selector(markProvider(_:)))
        check.identifier = NSUserInterfaceItemIdentifier(provider.id.uuidString)
        check.setAccessibilityLabel("Выбрать провайдера \(provider.displayTitle)")
        check.state = markedProviders.contains(provider.id) ? .on : .off
        check.isEnabled = !providerIsProtected(provider.id)
        if !check.isEnabled { check.toolTip = "Профиль используется в «Постобработке»" }

        let menu = SettingsDataTable.iconButton("ellipsis", "Действия с провайдером \(provider.displayTitle)",
                                                target: self, action: #selector(providerMenu(_:)))
        menu.identifier = NSUserInterfaceItemIdentifier(provider.id.uuidString)
        return [
            SettingsDataTable.padded(check, layout: .leading),
            SettingsDataTable.padded(SettingsDataTable.label(provider.displayTitle)),
            SettingsDataTable.padded(SettingsDataTable.label(provider.typeTitle)),
            SettingsDataTable.padded(SettingsDataTable.label(provider.model)),
            SettingsDataTable.padded(menu, layout: .trailing)
        ]
    }

    @objc private func markProvider(_ sender: NSButton) {
        guard let id = providerID(from: sender), !providerIsProtected(id),
              providers.contains(where: { $0.id == id }) else { return }
        if sender.state == .on { markedProviders.insert(id) } else { markedProviders.remove(id) }
        updateProviderCount()
    }

    private func updateProviderCount() {
        providersGrid?.showCount(providers.count, selected: markedProviders.count)
        removeProvidersButton.isEnabled = !markedProviders.isEmpty
    }

    @objc private func providerMenu(_ sender: NSButton) {
        guard let id = providerID(from: sender) else { return }
        let menu = NSMenu()
        let edit = NSMenuItem(title: "Изменить…", action: #selector(editProviderMenu(_:)), keyEquivalent: "")
        edit.target = self
        edit.representedObject = id
        menu.addItem(edit)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func editProviderMenu(_ item: NSMenuItem) {
        guard let id = item.representedObject as? UUID else { return }
        editProvider(id: id)
    }

    private func refreshProvidersList() {
        guard let providersGrid else { return }
        markedProviders.formIntersection(providers.filter { !providerIsProtected($0.id) }.map(\.id))
        providersGrid.showRows(providers.map(providerCells))
        updateProviderCount()
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
        if let dictationProviderNote {
            setLabel(dictationProviderNote, dictation == nil
                ? "AI не используется: вставляется сырой текст Whisper."
                : "Используется для исправления распознанного текста.")
        }
        if let improveProviderNote {
            setLabel(improveProviderNote, improve == nil
                ? (improveEnabledCheck?.state == .on
                    ? "Выберите провайдера для улучшения."
                    : "Улучшение выключено.")
                : "Используется при ⌥⌘E.")
        }
        promptGroup?.needsLayout = true
        improveGroup?.needsLayout = true
    }

    @objc private func addProvider() {
        let provider = AIProvider(name: "",
                                  kind: .opencode,
                                  providerID: "deepseek",
                                  model: "deepseek-flash",
                                  baseURL: "")
        showProviderEditor(provider, apiKey: "")
    }

    private func editProvider(id: UUID) {
        guard let provider = providers.first(where: { $0.id == id }) else { return }
        showProviderEditor(provider, apiKey: providerKeys[id] ?? "")
    }

    @objc private func deleteMarkedProviders() {
        let ids = markedProviders.filter { !providerIsProtected($0) }
        guard !ids.isEmpty else { return }
        let confirm = NSAlert()
        confirm.messageText = "Удалить выбранные профили?"
        confirm.informativeText = "Выбрано: \(ids.count). Профили и их API-ключи будут удалены после сохранения настроек."
        confirm.addButton(withTitle: "Удалить")
        confirm.addButton(withTitle: "Отмена")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        let removable = ids.filter { !providerIsProtected($0) }
        providers.removeAll { removable.contains($0.id) }
        for id in removable { providerKeys.removeValue(forKey: id) }
        markedProviders.removeAll()
        refreshProvidersList()
        refreshProviderMenus()
        updateDirtyState()
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
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = SettingsStyle.sectionSpacing

        dictationProviderPopup = NSPopUpButton()
        dictationProviderPopup.target = self
        dictationProviderPopup.action = #selector(dictationProviderChanged)
        dictationProviderPopup.widthAnchor.constraint(lessThanOrEqualToConstant: 330).isActive = true
        dictationProviderNote = SettingsText.footnote("", width: 520)

        promptTestLabel = SettingsText.footnote("")
        promptTestLabel.maximumNumberOfLines = 2

        let dictationCard = SettingsCard()
        dictationCard.addRow(SettingsRow(title: "Провайдер",
                                         subtitle: "Профили настраиваются в «Провайдерах».",
                                         subtitleView: dictationProviderNote,
                                         trailing: [dictationProviderPopup],
                                         subtitleWidth: 250))

        promptGroup = buildPromptSection()
        improveGroup = buildImproveSection()
        summaryGroup = buildSummarySection()

        root.addArrangedFullWidth(SettingsSection(title: "Исправление диктовки", card: dictationCard))
        root.addArrangedFullWidth(promptGroup)
        root.addArrangedFullWidth(improveGroup)
        root.addArrangedFullWidth(summaryGroup)
        return root
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
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = SettingsStyle.sectionSpacing

        historyEnabledCheck = NSSwitch()
        historyEnabledCheck.identifier = NSUserInterfaceItemIdentifier("history-enabled")

        historySearch = NSSearchField()
        historySearch.placeholderString = "Поиск по тексту"
        historySearch.delegate = self
        historySearch.widthAnchor.constraint(equalToConstant: 240).isActive = true
        let refresh = SettingsText.secondaryButton("Обновить", target: self, action: #selector(reloadHistoryAction))

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

        let itemsSuffix = SettingsText.rowSubtitle("сообщений", width: 90)
        let daysSuffix = SettingsText.rowSubtitle("дней", width: 60)
        let storageCard = SettingsCard()
        storageCard.addRow(SettingsRow(title: "Сохранять историю распознаваний",
                                       subtitle: "Тексты хранятся только на этом Mac.",
                                       trailing: [historyEnabledCheck]))
        storageCard.addRow(SettingsRow(title: "Хранить последних",
                                       trailing: [historyItemsField, historyItemsStepper, itemsSuffix]))
        storageCard.addRow(SettingsRow(title: "Удалять старше",
                                       trailing: [historyDaysField, historyDaysStepper, daysSuffix]))

        let searchSpacer = NSView()
        searchSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let searchRow = NSStackView(views: [historySearch, refresh, searchSpacer])
        searchRow.alignment = .centerY
        searchRow.spacing = 8
        historyGrid = SettingsDataTable("Записи истории", columns: [
            .init(id: "date", title: "Когда", width: 135, fixed: true),
            .init(id: "text", title: "Текст", width: 483)
        ], header: searchRow, actions: [clearHistoryButton], empty: "История пуста")
        historyTable = historyGrid.table
        historyTable.dataSource = self
        historyTable.delegate = self
        historyTable.target = self
        historyTable.doubleAction = #selector(copySelectedHistory)

        historyStatusLabel = SettingsText.rowSubtitle("", width: 160)
        let copy = SettingsText.linkButton("Копировать", target: self, action: #selector(copySelectedHistory))
        let delete = SettingsText.destructiveButton("Удалить", target: self, action: #selector(deleteSelectedHistory))
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let detailHeader = NSStackView(views: [historyStatusLabel, spacer, copy, delete])
        detailHeader.orientation = .horizontal
        detailHeader.alignment = .centerY
        detailHeader.spacing = 12

        historyDetail = NSTextView()
        historyDetail.isEditable = false
        historyDetail.isSelectable = true
        historyDetail.font = .systemFont(ofSize: 12)
        historyDetail.string = "Выберите запись в списке."
        let detailScroll = makeScroll(historyDetail)
        detailScroll.heightAnchor.constraint(equalToConstant: 130).isActive = true

        let detailCard = SettingsCard()
        detailCard.addRow(SettingsContentRow(detailHeader, verticalInset: 10))
        detailCard.addRow(SettingsSeparatorView(height: 1, color: SettingsStyle.cardBorder), separated: false)
        detailCard.addRow(detailScroll, separated: false)

        root.addArrangedFullWidth(SettingsSection(title: "Хранение", card: storageCard))
        root.addArrangedFullWidth(SettingsSection(title: "Записи", card: historyGrid))
        let detailSection = SettingsSection(title: "Выбранная запись", card: detailCard)
        historyDetailSection = detailSection
        root.addArrangedFullWidth(detailSection)
        return root
    }

    private func reloadHistory() {
        guard historyTable != nil else { return }
        HistoryStore.shared.load()
        let query = historySearch?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let all = HistoryStore.shared.entries
        historyRecordCount = all.count
        if query.isEmpty {
            filteredHistory = all
        } else {
            filteredHistory = all.filter {
                $0.text.localizedCaseInsensitiveContains(query)
                    || ($0.raw?.localizedCaseInsensitiveContains(query) ?? false)
            }
        }
        historyTable.reloadData()
        historyGrid.showCount(historyRecordCount, visible: filteredHistory.count,
                              empty: all.isEmpty ? "История пуста" : "Совпадений не найдено")
        clearHistoryButton.isEnabled = !all.isEmpty
        historyStatusLabel?.stringValue = ""
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
            self.historyStatusLabel.stringValue = ""
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
        alert.informativeText = "Все сохранённые распознавания, включая записи вне текущего поиска, будут удалены."
        alert.addButton(withTitle: "Очистить")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        HistoryStore.shared.clear()
        reloadHistory()
    }

    // MARK: - Модели

    private func buildModels() -> NSView {
        languagePopup = NSPopUpButton()
        languagePopup.addItems(withTitles: ["Русский", "English", "Авто"])
        languagePopup.setAccessibilityLabel("Язык распознавания")
        technologyPopup.addItems(withTitles: RecognitionTechnology.allCases.map(\.title))
        technologyPopup.setAccessibilityLabel("Технология распознавания")
        technologyPopup.autoenablesItems = false
        technologyPopup.target = self
        technologyPopup.action = #selector(changeRecognitionTechnology)
        technologyPopup.item(at: 1)?.isEnabled = FluidModelStore.supported
        if !FluidModelStore.supported { technologyPopup.item(at: 1)?.title += " · требуется Apple Silicon" }

        modelsStack = NSStackView()
        modelsStack.orientation = .vertical
        modelsStack.alignment = .width
        modelsStack.spacing = SettingsStyle.sectionSpacing
        return modelsStack
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
        fluidStatuses.removeAll()
        fluidBars.removeAll()

        technologyPopup.selectItem(at: RecognitionTechnology.allCases.firstIndex(of: selectedTechnology) ?? 0)

        let languageNote: String
        if selectedTechnology == .whisper {
            languageNote = "Язык — подсказка модели. Для русской речи с английскими терминами сравните «Русский» и «Авто» на своём голосе."
        } else if selectedFluidModel == .nemotron {
            languageNote = "Язык задаёт подсказку потоковой модели. Для смешанной русско-английской речи начните с «Авто»."
        } else {
            languageNote = "Здесь выбор языка ограничивает алфавит: «Русский» — кириллица, English — латиница. Для русского с английскими словами выберите «Авто», чтобы снять это ограничение."
        }

        let engineCard = SettingsCard()
        engineCard.addRow(SettingsRow(title: "Технология распознавания",
                                      subtitle: "Определяет доступные модели. Распознавание идёт локально.",
                                      trailing: [technologyPopup],
                                      subtitleWidth: 300))
        engineCard.addRow(SettingsRow(title: "Язык распознавания",
                                      subtitle: languageNote,
                                      trailing: [languagePopup],
                                      subtitleWidth: 300))
        engineCard.addRow(SettingsContentRow(previewControls, verticalInset: 12))
        addSection(SettingsSection(title: "Движок", card: engineCard))

        if !recognitionValidationMessage.isEmpty {
            addSectionFootnote(SettingsText.footnote(recognitionValidationMessage))
        }

        addModelTables()
    }

    private func addSection(_ view: NSView) {
        modelsStack.addArrangedSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: modelsStack.widthAnchor).isActive = true
    }

    private func addSectionFootnote(_ view: NSView) {
        let wrapper = NSStackView()
        wrapper.orientation = .vertical
        wrapper.alignment = .leading
        wrapper.addArrangedFullWidth(view)
        modelsStack.addArrangedSubview(wrapper)
        wrapper.widthAnchor.constraint(equalTo: modelsStack.widthAnchor).isActive = true
    }

    private func addModelTables() {
        let whisper = selectedTechnology == .whisper
        let found = whisper ? knownWhisperModels() : []
        let installed = whisper ? [] : FluidModel.allCases.filter { FluidModelStore.installed($0) }
        var actions = [SettingsText.secondaryButton("Открыть папку моделей", target: self, action: #selector(openModelsFolder))]
        if whisper {
            actions.append(SettingsDataTable.iconButton("plus", "Добавить внешний файл…", target: self, action: #selector(addModelFile)))
        }
        let local = SettingsDataTable("Найдены на компьютере", columns: [
            .init(id: "active", title: "", width: 34, fixed: true),
            .init(id: "model", title: "Модель", width: 300),
            .init(id: "size", title: "Размер", width: 92, fixed: true, headerAlignment: .right),
            .init(id: "actions", title: "Действия", width: 232, fixed: true, headerAlignment: .right)
        ], rowHeight: 44, height: 157, actions: actions, empty: "Модели не найдены")
        local.showRows(whisper ? found.map(whisperModelCells) : installed.map(fluidModelCells))
        addSection(SettingsSection(title: "Найдены на компьютере", card: local))
        if whisper, !selectedModelPath.isEmpty, WhisperModelStore.file(at: selectedModelPath) == nil {
            addSectionFootnote(SettingsText.footnote("Выбранная модель недоступна. Выберите другую.", warning: true))
        } else if !whisper, !FluidModelStore.installed(selectedFluidModel) {
            addSectionFootnote(SettingsText.footnote("Для диктовки скачайте \(selectedFluidModel.title) или выберите установленную модель.", warning: true))
        }

        let catalog = SettingsDataTable("Скачивание", columns: [
            .init(id: "model", title: "Модель", width: 340),
            .init(id: "size", title: "Размер", width: 92, fixed: true, headerAlignment: .right),
            .init(id: "status", title: "Состояние", width: 181, fixed: true),
            .init(id: "actions", title: "Действия", width: 96, fixed: true, headerAlignment: .right)
        ], rowHeight: 52, height: 182, empty: "Все совместимые модели скачаны")
        if whisper {
            let names = Set(found.map(\.fileName))
            let missing = WhisperModelCatalog.models.filter { downloads[$0.id] != nil || !names.contains($0.fileName) }
                .sorted { $0.recommended != $1.recommended ? $0.recommended : $0.sizeBytes < $1.sizeBytes }
            catalog.showRows(missing.map(whisperDownloadCells))
        } else {
            catalog.showRows(FluidModel.allCases.filter { !installed.contains($0) }.map(fluidDownloadCells))
        }
        addSection(SettingsSection(title: "Скачивание",
                                   note: "Модели скачиваются в хранилище Runvoice.", card: catalog))
        if !whisper, selectedFluidModel.usesWindowedRecognition {
            addSectionFootnote(SettingsText.footnote("Технический словарь для этой модели учитывается при AI-правке текста."))
        }
    }

    private func knownWhisperModels() -> [WhisperModelFile] {
        var files = WhisperModelStore.foundModels(extraDirectories: modelDirs,
                                                externalPaths: externalModelPaths, excluding: hiddenModelPaths)
        if let active = WhisperModelStore.file(at: selectedModelPath), !hiddenModelPaths.contains(active.path),
           !files.contains(where: { $0.path == active.path }) {
            files.insert(active, at: 0)
        }
        return files
    }

    private func modelText(_ name: String, _ detail: String, isPath: Bool = false,
                           status: NSTextField? = nil) -> NSView {
        let subtitle = status ?? SettingsDataTable.label(detail, secondary: true)
        if isPath { subtitle.lineBreakMode = .byTruncatingMiddle }
        let labels = NSStackView(views: [SettingsDataTable.label(name), subtitle])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        return SettingsDataTable.padded(labels)
    }

    private func modelControl(_ symbol: String, _ title: String, _ id: String, _ action: Selector) -> NSButton {
        let button = SettingsDataTable.iconButton(symbol, title, target: self, action: action)
        button.identifier = NSUserInterfaceItemIdentifier(id)
        return button
    }

    private func modelChoice(_ title: String, id: String, selected: Bool, action: Selector) -> NSButton {
        let radio = NSButton(radioButtonWithTitle: "", target: self, action: action)
        radio.setAccessibilityLabel("Использовать \(title)")
        radio.identifier = NSUserInterfaceItemIdentifier(id)
        radio.state = selected ? .on : .off
        return radio
    }

    private func installedActions(path: String, id: String, fluid: Bool) -> NSView {
        let finder = SettingsText.secondaryButton("Показать в Finder", target: self, action: #selector(revealModel(_:)))
        finder.identifier = NSUserInterfaceItemIdentifier(path)
        finder.controlSize = .small
        var buttons = [finder]
        if fluid {
            let busy = downloadingFluidModel?.rawValue == id
            let button = modelControl(busy ? "xmark.circle" : "checkmark.circle",
                                      busy ? "Отменить проверку" : "Проверить", id, #selector(downloadFluidModel(_:)))
            button.isEnabled = busy || fluidDownload == nil
            buttons.append(button)
        }
        let delete = modelControl("trash", "Удалить модель…", id,
                                  fluid ? #selector(deleteFluidModel(_:)) : #selector(deleteModel(_:)))
        delete.contentTintColor = .systemRed
        delete.isEnabled = !fluid || downloadingFluidModel?.rawValue != id
        buttons.append(delete)
        let actions = NSStackView(views: buttons)
        actions.alignment = .centerY
        actions.spacing = 4
        return SettingsDataTable.padded(actions, layout: .trailing)
    }

    private func whisperModelCells(_ model: WhisperModelFile) -> [NSView] {
        let title = model.catalogModel?.title ?? model.fileName
        let name = model.catalogModel?.experimental == true ? title + " · экспериментальная" : title
        let radio = modelChoice(name, id: model.path, selected: model.path == selectedModelPath, action: #selector(selectModel(_:)))
        return [
            SettingsDataTable.padded(radio, layout: .leading),
            modelText(name, model.isManaged ? "Хранилище Runvoice" : "Внешний файл · " + model.directory, isPath: true),
            SettingsDataTable.padded(SettingsDataTable.label(model.sizeText, alignment: .right)),
            installedActions(path: model.path, id: model.path, fluid: false)
        ]
    }

    private func fluidModelCells(_ model: FluidModel) -> [NSView] {
        let radio = modelChoice(model.title, id: model.rawValue, selected: selectedFluidModel == model, action: #selector(selectFluidModel(_:)))
        let busy = downloadingFluidModel == model
        let status = SettingsDataTable.label(busy ? "Проверка: \(Int(fluidDownloadProgress * 100))%" : fluidErrors[model] ?? model.detail,
                                             secondary: true)
        if fluidErrors[model] != nil { status.textColor = .systemOrange }
        if busy { fluidStatuses[model] = status }
        return [
            SettingsDataTable.padded(radio, layout: .leading),
            modelText(model.title, model.detail, status: status),
            SettingsDataTable.padded(SettingsDataTable.label(model.estimatedSize, alignment: .right)),
            installedActions(path: FluidModelStore.directory(for: model).path, id: model.rawValue, fluid: true)
        ]
    }

    private func progressBar(_ fraction: Double) -> NSProgressIndicator {
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.doubleValue = fraction
        bar.heightAnchor.constraint(equalToConstant: 6).isActive = true
        return bar
    }

    private func modelStatus(_ text: String, warning: Bool = false, waiting: Bool = false,
                             fraction: Double = 0, speed: String? = nil)
        -> (cell: NSView, label: NSTextField, bar: NSProgressIndicator, speed: NSTextField) {
        let label = SettingsDataTable.label(text, secondary: true)
        if warning { label.textColor = .systemOrange }
        let bar = progressBar(fraction)
        let rate = SettingsDataTable.label(speed ?? "", secondary: true)
        let views: [NSView] = waiting ? [label, bar] + (speed == nil ? [] : [rate]) : [label]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        if waiting { bar.widthAnchor.constraint(equalToConstant: 106).isActive = true }
        return (SettingsDataTable.padded(stack), label, bar, rate)
    }

    private func downloadControl(_ id: String, busy: Bool, retry: Bool, action: Selector) -> NSButton {
        let title = busy ? "Отменить загрузку" : retry ? "Повторить загрузку" : "Скачать"
        let symbol = busy ? "xmark.circle" : retry ? "arrow.clockwise" : "arrow.down.to.line"
        return modelControl(symbol, title, id, action)
    }

    private func whisperDownloadCells(_ model: WhisperModel) -> [NSView] {
        let id = model.id
        let busy = downloads[id] != nil
        let fraction = downloadProgress[id] ?? 0
        let free = ((try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()))?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        let noSpace = free < model.sizeBytes + 200 * 1024 * 1024
        let error = downloadErrors[id]
        let status = modelStatus(busy ? "Загрузка: \(Int(fraction * 100))%" :
            noSpace ? "Недостаточно места" : error ?? "Не скачана",
            warning: !busy && (error != nil || noSpace), waiting: busy, fraction: fraction,
            speed: busy ? speedText(downloadSpeeds[id] ?? 0, model: model, progress: fraction) : nil)
        if busy {
            downloadBars[id] = status.bar
            downloadPercents[id] = status.label
            downloadSpeedLabels[id] = status.speed
        }
        let button = downloadControl(id, busy: busy, retry: error != nil, action: #selector(downloadModel(_:)))
        button.isEnabled = busy || !noSpace
        if noSpace && !busy { button.toolTip = "Для загрузки нужно \(model.sizeText) плюс запас 200 МБ." }
        let title = model.experimental ? model.title + " · экспериментальная" : model.title
        return [modelText(title, model.note), SettingsDataTable.padded(SettingsDataTable.label(model.sizeText, alignment: .right)),
                status.cell, SettingsDataTable.padded(button, layout: .trailing)]
    }

    private func fluidDownloadCells(_ model: FluidModel) -> [NSView] {
        let busy = downloadingFluidModel == model
        let error = fluidErrors[model]
        let status = modelStatus(busy ? "Загрузка: \(Int(fluidDownloadProgress * 100))%" : error ?? "Не скачана",
                                 warning: error != nil, waiting: busy, fraction: fluidDownloadProgress)
        if busy {
            fluidStatuses[model] = status.label
            fluidBars[model] = status.bar
        }
        let button = downloadControl(model.rawValue, busy: busy, retry: error != nil, action: #selector(downloadFluidModel(_:)))
        button.isEnabled = fluidDownload == nil || busy
        return [modelText(model.title, model.detail),
                SettingsDataTable.padded(SettingsDataTable.label(model.estimatedSize, alignment: .right)),
                status.cell, SettingsDataTable.padded(button, layout: .trailing)]
    }

    @objc private func openModelsFolder() {
        NSWorkspace.shared.open(WhisperModelStore.modelsDirectory)
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
        guard !UpdateCoordinator.shared.isInstalling else { return }
        guard selectedTechnology == .whisper,
              let id = sender.identifier?.rawValue,
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
        downloadErrors[id] = nil
        downloadProgress[id] = 0

        downloader.onProgress = { [weak self, weak downloader] value, speed in
            guard let self, let downloader, self.downloads[id] === downloader else { return }
            self.downloadProgress[id] = value
            self.downloadSpeeds[id] = speed
            self.downloadBars[id]?.doubleValue = value
            self.downloadPercents[id]?.stringValue = "Загрузка: \(Int(value * 100))%"
            self.downloadPercents[id]?.isHidden = false
            self.downloadSpeedLabels[id]?.stringValue = self.speedText(speed, model: model, progress: value)
            self.downloadSpeedLabels[id]?.isHidden = false
        }
        downloader.onFinish = { [weak self, weak downloader] result in
            guard let self, let downloader, self.downloads[id] === downloader else { return }
            self.downloads[id] = nil
            self.downloadProgress[id] = nil
            self.downloadSpeeds[id] = nil
            switch result {
            case .success(let url):
                self.refreshModels()
                self.refreshDiagnostics(force: true)
                Log.write("model: скачана \(url.lastPathComponent)")
            case .failure(let error):
                self.downloadErrors[id] = "Не удалось скачать"
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

    @objc private func selectModel(_ sender: NSButton) {
        guard selectedTechnology == .whisper,
              let path = sender.identifier?.rawValue,
              WhisperModelStore.file(at: path) != nil else { return }
        selectedModelPath = path
        recognitionValidationMessage = ""
        refreshModels()
    }

    @objc private func revealModel(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func modelRemovalAllowed() -> Bool {
        guard canRemoveModel(), !UpdateCoordinator.shared.isInstalling else {
            let alert = NSAlert()
            alert.messageText = "Модель сейчас может использоваться"
            alert.informativeText = "Дождитесь завершения распознавания или обновления и повторите."
            alert.runModal()
            return false
        }
        return true
    }

    @objc private func deleteModel(_ sender: NSButton) {
        guard selectedTechnology == .whisper, let path = sender.identifier?.rawValue,
              let model = WhisperModelStore.file(at: path), modelRemovalAllowed() else { return }
        if !model.isManaged {
            let alert = NSAlert()
            alert.messageText = "Удалить «\(model.fileName)»?"
            alert.informativeText = "При удалении из приложения файл останется на диске.\n\n\(model.path)"
            alert.addButton(withTitle: "Отмена")
            alert.addButton(withTitle: "Удалить из приложения")
            alert.addButton(withTitle: "Удалить с диска…")
            switch alert.runModal() {
            case .alertSecondButtonReturn:
                forgetWhisperModel(path, excludeFile: true)
                return
            case .alertThirdButtonReturn: break
            default: return
            }
        }
        let detail = "Файл модели будет удалён с диска. Это действие нельзя отменить.\n\n" + model.path
        guard confirmDiskRemoval(model.fileName, detail: detail),
              modelRemovalAllowed() else { return }
        do {
            guard WhisperModelStore.file(at: path) != nil else { throw CocoaError(.fileNoSuchFile) }
            try FileManager.default.removeItem(atPath: path)
            forgetWhisperModel(path, excludeFile: false)
            onModelRemoved?()
        } catch { reportModelRemoval(error) }
    }

    @objc private func deleteFluidModel(_ sender: NSButton) {
        guard selectedTechnology == .fluidAudio, let id = sender.identifier?.rawValue,
              let model = FluidModel(rawValue: id), FluidModelStore.installed(model),
              downloadingFluidModel != model, modelRemovalAllowed(),
              confirmDiskRemoval(model.title, detail: "Папка модели будет удалена с диска. Это действие нельзя отменить."),
              downloadingFluidModel != model, modelRemovalAllowed() else { return }
        do {
            try FluidModelStore.removeInstalled(model)
            fluidErrors[model] = nil
            refreshModels()
            refreshAPI()
            onModelRemoved?()
        } catch { reportModelRemoval(error) }
    }

    private func forgetWhisperModel(_ path: String, excludeFile: Bool) {
        externalModelPaths.removeAll { $0 == path }
        if excludeFile, !hiddenModelPaths.contains(path) { hiddenModelPaths.append(path) }
        if selectedModelPath == path { selectedModelPath = "" }
        refreshModels()
        refreshAPI()
        updateDirtyState()
    }

    private func confirmDiskRemoval(_ name: String, detail: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Удалить «\(name)» с диска?"
        alert.informativeText = detail
        alert.addButton(withTitle: "Отмена")
        let remove = alert.addButton(withTitle: "Удалить с диска")
        remove.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func reportModelRemoval(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Не удалось удалить модель"
        alert.informativeText = error.localizedDescription
        alert.runModal()
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
        let path = url.standardized.path
        if !WhisperModelStore.isManaged(path: path), !externalModelPaths.contains(path) { externalModelPaths.append(path) }
        hiddenModelPaths.removeAll { $0 == path }
        selectedModelPath = path
        recognitionValidationMessage = ""
        refreshModels()
    }

    // MARK: - Prompt

    private func buildImproveSection() -> NSStackView {
        improveEnabledCheck = NSSwitch()
        improveEnabledCheck.identifier = NSUserInterfaceItemIdentifier("improve-enabled")
        improveEnabledCheck.target = self
        improveEnabledCheck.action = #selector(improveEnabledChanged)
        improveProviderPopup = NSPopUpButton()
        improveProviderPopup.target = self
        improveProviderPopup.action = #selector(improveProviderChanged)
        improveProviderPopup.widthAnchor.constraint(lessThanOrEqualToConstant: 330).isActive = true
        improveProviderNote = SettingsText.footnote("", width: 520)
        improveTestLabel = SettingsText.footnote("")
        improveTestLabel.maximumNumberOfLines = 2

        let card = SettingsCard()
        card.addRow(SettingsRow(title: "Включить улучшение выделенного текста",
                                subtitle: "Работает по сочетанию ⌥⌘E.",
                                trailing: [improveEnabledCheck]))
        card.addRow(SettingsRow(title: "Провайдер",
                                subtitleView: improveProviderNote,
                                trailing: [improveProviderPopup],
                                subtitleWidth: 250))
        addPromptEditor(improveText, height: 170, status: improveTestLabel,
                        reset: #selector(resetImprovePromptToDefault), test: #selector(testImprovePrompt), to: card)

        return SettingsSection(title: "Улучшение выделенного текста",
                               note: "Провайдер и модель выбираются здесь; профили — в «Провайдерах». Пустое поле промпта заменяется встроенным.",
                               card: card)
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

    private func buildSummarySection() -> NSStackView {
        summaryTestLabel = SettingsText.footnote("")
        summaryTestLabel.maximumNumberOfLines = 2

        let card = SettingsCard()
        addPromptEditor(summaryText, height: 150, status: summaryTestLabel,
                        reset: #selector(resetSummaryPromptToDefault), test: #selector(testSummaryPrompt), to: card)

        return SettingsSection(title: "Саммари расшифровки аудио",
                               note: "Используется провайдер для улучшения текста. Пустое поле заменяется встроенным промптом. Кастомный промпт в окне расшифровки заменяет этот текст для финального саммари.",
                               card: card)
    }

    @objc private func resetSummaryPromptToDefault() {
        summaryText.string = DefaultPrompts.summary
    }

    @objc private func testSummaryPrompt() {
        guard let provider = providers.first(where: { $0.id == improveProviderID }) else {
            summaryTestLabel.stringValue = "Выберите провайдера для улучшения текста."
            summaryTestLabel.textColor = .systemOrange
            return
        }
        let prompt = summaryText.string.isEmpty ? DefaultPrompts.summary : summaryText.string
        summaryTestLabel.stringValue = "Проверяю…"
        summaryTestLabel.textColor = .secondaryLabelColor
        CorrectionTester.test(provider: provider, prompt: prompt) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let text):
                self.summaryTestLabel.stringValue = "✓ \(text)"
                self.summaryTestLabel.textColor = .systemGreen
            case .failure(let error):
                self.summaryTestLabel.stringValue = "⚠️ \(error.localizedDescription)"
                self.summaryTestLabel.textColor = .systemOrange
            }
        }
    }

    private func buildPromptSection() -> NSStackView {
        let card = SettingsCard()
        addPromptEditor(fixText, height: 220, status: promptTestLabel,
                        reset: #selector(resetPromptToDefault), test: #selector(testPrompt), to: card)
        return SettingsSection(title: "Промпт для исправления текста (⌥Space)",
                               note: "Используется при включённой постобработке. Пустое поле заменяется встроенным промптом.",
                               card: card)
    }

    private func addPromptEditor(_ text: NSTextView, height: CGFloat, status: NSTextField,
                                 reset: Selector, test: Selector, to card: SettingsCard) {
        let resetButton = SettingsText.secondaryButton("Сбросить к встроенному", target: self, action: reset)
        let testButton = SettingsText.secondaryButton("Проверить на примере", target: self, action: test)
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        status.preferredMaxLayoutWidth = 300
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [resetButton, testButton, status, spacer])
        buttons.alignment = .centerY
        buttons.spacing = 8
        let scroll = makeScroll(text)
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        card.addRow(SettingsContentRow(buttons, verticalInset: 8))
        card.addRow(SettingsSeparatorView(height: 1, color: SettingsStyle.cardBorder), separated: false)
        card.addRow(scroll, separated: false)
    }

    private func makeScroll(_ textView: NSTextView) -> NSScrollView {
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: SettingsStyle.rowHorizontalInset, height: 8)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.focusRingType = .none
        scroll.documentView = textView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }

    // MARK: - Hotkeys

    private func buildHotkeys() -> NSView {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = SettingsStyle.sectionSpacing

        toggleHotkeyButton = SettingsText.secondaryButton(toggleHotkey.display,
                                                          target: self,
                                                          action: #selector(captureToggle))
        toggleHotkeyButton.widthAnchor.constraint(equalToConstant: 190).isActive = true
        improveHotkeyButton = SettingsText.secondaryButton(improveHotkey.display,
                                                           target: self,
                                                           action: #selector(captureImprove))
        improveHotkeyButton.widthAnchor.constraint(equalToConstant: 190).isActive = true

        stopOnEnterCheck.identifier = NSUserInterfaceItemIdentifier("stop-recording-on-enter")
        cancelOnEscapeCheck.identifier = NSUserInterfaceItemIdentifier("cancel-recording-on-escape")
        pauseOnSpaceCheck.identifier = NSUserInterfaceItemIdentifier("pause-recording-on-space")

        let shortcutsCard = SettingsCard()
        shortcutsCard.addRow(SettingsRow(title: "Диктовка",
                                         subtitle: "Начало и завершение записи.",
                                         trailing: [toggleHotkeyButton]))
        shortcutsCard.addRow(SettingsRow(title: "Улучшение текста",
                                         subtitle: "Правка выделенного текста через AI.",
                                         trailing: [improveHotkeyButton]))

        let recordingCard = SettingsCard()
        recordingCard.addRow(SettingsRow(title: "Останавливать распознавание по нажатию Enter",
                                         subtitle: "Во время записи и на паузе Enter завершает диктовку и запускает обработку текста.",
                                         trailing: [stopOnEnterCheck]))
        recordingCard.addRow(SettingsRow(title: "Отменять диктовку по Esc",
                                         subtitle: "Во время записи и на паузе Esc отменяет диктовку без распознавания и вставки текста.",
                                         trailing: [cancelOnEscapeCheck]))
        recordingCard.addRow(SettingsRow(title: "Пауза диктовки по пробелу",
                                         subtitle: "Пробел ставит диктовку на паузу; повторное нажатие продолжает запись. Сочетания с модификаторами работают как обычно.",
                                         trailing: [pauseOnSpaceCheck]))

        root.addArrangedFullWidth(SettingsSection(title: "Сочетания",
                                                note: "Для сочетаний нужен хотя бы один модификатор из ⌃ / ⌥ / ⌘.",
                                                card: shortcutsCard))
        root.addArrangedFullWidth(SettingsSection(title: "Во время записи", card: recordingCard))
        return root
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
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        setLabel(updateStatusLabel, "Версия \(version). " + UpdateCoordinator.shared.status)
        refreshAPI()
        let ok = AXIsProcessTrusted()
        accessLabel.stringValue = ok ? "✓ разрешено" : "⚠️ нет доступа"
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
            if settings.recognitionTechnology == .fluidAudio, FluidModelStore.supported {
                let title = settings.fluidModel.title
                return FluidModelStore.installed(settings.fluidModel)
                    ? ("✓ FluidAudio: \(title) — скачана и проверена", .systemGreen)
                    : ("⚠️ \(title) — скачайте в «Распознавание» → FluidAudio", .systemOrange)
            }
            if let model = WhisperModelStore.activeModel(settings: settings) {
                let title = WhisperModelCatalog.models
                    .first { $0.fileName == model.fileName }?.title ?? model.fileName
                let source = model.isManaged ? "скачана приложением" : model.directory
                return ("✓ Модель Whisper: \(title) · \(model.sizeText) — \(source)", .systemGreen)
            }
            if settings.whisperModelPath.isEmpty {
                return ("⚠️ Модель Whisper не выбрана — Настройки → Распознавание", .systemOrange)
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

    func showAudioSamples() {
        guard let window, window.attachedSheet == nil else { return }
        if samplePanel == nil {
            samplePanel = AudioSamplePanel(microphone: { [weak self] in
                (self?.micPopup.titleOfSelectedItem ?? "",
                 self?.micPopup.selectedItem?.representedObject as? String ?? "")
            })
        }
        samplePanel?.present(on: window)
    }

    func prepareSampleSnapshot(recording: Bool = false) -> NSView? {
        showAudioSamples()
        samplePanel?.prepareSnapshot(recording: recording)
        return samplePanel?.window?.contentView
    }

    private func setMicTest(_ text: String, color: NSColor) {
        micTestLabel.stringValue = text
        micTestLabel.textColor = color
        micTestLabel.invalidateIntrinsicContentSize()
        micTestRow?.isHidden = text.isEmpty
    }

    @objc private func testMicrophone() {
        let name = micPopup.titleOfSelectedItem ?? ""
        micTestButton.isEnabled = false
        setMicTest("Запись 1 с…", color: .secondaryLabelColor)
        let uid = micPopup.selectedItem?.representedObject as? String ?? ""
        MicTester.test(micName: name, deviceUID: uid) { [weak self] result in
            guard let self else { return }
            self.micTestButton.isEnabled = true
            switch result {
            case .success(let level):
                let value = Double(level.replacingOccurrences(of: ",", with: ".")) ?? -100
                if value > -50 {
                    self.setMicTest("✓ \(level) dB", color: .systemGreen)
                } else {
                    self.setMicTest("⚠️ тишина (\(level) dB)", color: .systemOrange)
                }
            case .failure(let error):
                self.setMicTest("⚠️ \(error.localizedDescription)", color: .systemOrange)
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

    @objc private func changeRecognitionTechnology() {
        let index = max(0, technologyPopup.indexOfSelectedItem)
        let technology = RecognitionTechnology.allCases[index]
        guard technology.isSupported else { return }
        selectedTechnology = technology
        recognitionValidationMessage = ""
        refreshModels()
    }

    @objc private func selectFluidModel(_ sender: NSButton) {
        guard selectedTechnology == .fluidAudio, FluidModelStore.supported,
              let raw = sender.identifier?.rawValue, let model = FluidModel(rawValue: raw),
              FluidModelStore.installed(model) else { return }
        selectedFluidModel = model
        recognitionValidationMessage = ""
        refreshModels()
    }

    @objc private func downloadFluidModel(_ sender: NSButton) {
        guard !UpdateCoordinator.shared.isInstalling else { return }
        guard selectedTechnology == .fluidAudio, FluidModelStore.supported,
              let raw = sender.identifier?.rawValue, let model = FluidModel(rawValue: raw) else { return }
        if let download = fluidDownload {
            guard downloadingFluidModel == model else { return }
            download.stop()
            fluidDownload = nil
            downloadingFluidModel = nil
            refreshModels()
            return
        }
        let download = ASRProcess(directory: FluidModelStore.directory(for: model))
        fluidDownload = download
        downloadingFluidModel = model
        fluidDownloadProgress = 0
        fluidErrors[model] = nil
        var completed = false
        download.onEvent = { [weak self, weak download] event in
            guard let self, let download, self.fluidDownload === download else { return }
            switch event["event"] as? String {
            case "progress":
                self.fluidDownloadProgress = max(0, min(1, event["progress"] as? Double ?? 0))
                let verb = FluidModelStore.installed(model) ? "Проверка" : "Загрузка"
                self.fluidStatuses[model]?.stringValue = "\(verb): \(Int(self.fluidDownloadProgress * 100))%"
                self.fluidBars[model]?.doubleValue = self.fluidDownloadProgress
            case "installed":
                completed = true
                self.fluidDownload = nil
                self.downloadingFluidModel = nil
                self.refreshModels()
            case "error":
                completed = true
                self.fluidDownload = nil
                self.downloadingFluidModel = nil
                self.fluidErrors[model] = "Не удалось загрузить или проверить модель. Повторите попытку"
                self.refreshModels()
            default: break
            }
        }
        download.onExit = { [weak self, weak download] in
            guard let self, let download, self.fluidDownload === download, !completed else { return }
            self.fluidDownload = nil
            self.downloadingFluidModel = nil
            self.fluidErrors[model] = "Загрузка прервана. Можно повторить"
            self.refreshModels()
        }
        do { try download.start(mode: "download", model: model) }
        catch {
            fluidDownload = nil
            downloadingFluidModel = nil
            fluidErrors[model] = "Не удалось запустить загрузку: \(error.localizedDescription)"
            refreshModels()
            return
        }
        refreshModels()
    }

    private func currentSettings() -> Settings {
        var settings = loadedSettings
        settings.promptFix = fixText.string
        settings.promptImprove = improveText.string
        settings.promptSummary = summaryText.string
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
        settings.pauseRecordingOnSpace = pauseOnSpaceCheck.state == .on
        settings.apiEnabled = apiEnable.state == .on
        settings.apiPort = Int(apiPortField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        settings.apiAudioFilterEnabled = apiFilter.state == .on
        settings.apiUseVocabulary = apiVocabulary.state == .on
        settings.apiMinimumSpeechDbfs = apiThreshold.doubleValue.rounded()
        settings.apiImproveText = apiImprove.state == .on
        settings.apiRecognitionModel = selectedAPIModel
        settings.whisperModelPath = selectedModelPath
        settings.whisperModelDirs = modelDirs
        settings.whisperExternalModelPaths = externalModelPaths
        settings.hiddenModelPaths = hiddenModelPaths
        settings.recognitionTechnology = selectedTechnology
        settings.fluidModel = selectedFluidModel
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
        selectedTechnology = settings.recognitionTechnology.isSupported ? settings.recognitionTechnology : .whisper
        selectedFluidModel = settings.fluidModel
        recognitionValidationMessage = ""
        vocabularyEditor.load(settings.speechVocabulary)
        previewControls.options = settings.recognitionPreview
        fixText.string = settings.promptFix.isEmpty ? DefaultPrompts.fix : settings.promptFix
        promptTestLabel?.stringValue = ""
        improveTestLabel?.stringValue = ""
        summaryTestLabel?.stringValue = ""
        setMicTest("", color: .secondaryLabelColor)

        languagePopup.selectItem(at: languages.firstIndex(of: settings.language) ?? 0)
        reloadMicrophones(selected: settings.microphone, uid: settings.microphoneUID)

        markedProviders.removeAll()
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
        summaryText.string = settings.promptSummary.isEmpty ? DefaultPrompts.summary : settings.promptSummary
        stopOnEnterCheck.state = settings.stopRecordingOnEnter ? .on : .off
        cancelOnEscapeCheck.state = settings.cancelRecordingOnEscape ? .on : .off
        pauseOnSpaceCheck.state = settings.pauseRecordingOnSpace ? .on : .off
        apiEnable.state = settings.apiEnabled ? .on : .off
        apiPortField.stringValue = String(settings.apiPort)
        apiFilter.state = settings.apiAudioFilterEnabled ? .on : .off
        apiVocabulary.state = settings.apiUseVocabulary ? .on : .off
        apiThreshold.doubleValue = settings.apiMinimumSpeechDbfs
        apiImprove.state = settings.apiImproveText ? .on : .off
        selectedAPIModel = settings.apiRecognitionModel
        improveEnabledCheck.state = settings.improveEnabled ? .on : .off
        updateAIProviderState()

        modelDirs = settings.whisperModelDirs
        externalModelPaths = settings.whisperExternalModelPaths
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
        loadedSettings.promptSummary = summaryText.string
        loadedSettings.improveEnabled = improveEnabledCheck.state == .on
        loadedSettings.whisperModelPath = selectedModelPath
        loadedSettings.recognitionTechnology = selectedTechnology
        loadedSettings.fluidModel = selectedFluidModel
        loadedSettings.microphone = micPopup.titleOfSelectedItem ?? loadedSettings.microphone
        loadedSettings.microphoneUID = micPopup.selectedItem?.representedObject as? String ?? ""
        updateDirtyState()
    }

    @objc private func resetDefaults() {
        let tabName = pageMeta(currentTab).title
        let confirm = NSAlert()
        confirm.messageText = "Сбросить раздел «\(tabName)»?"
        confirm.informativeText = "Несохранённые изменения в этом разделе будут заменены значениями по умолчанию."
        confirm.addButton(withTitle: "Сбросить")
        confirm.addButton(withTitle: "Отмена")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        switch currentTab {
        case "api":
            apiFilter.state = .on; apiVocabulary.state = .on; apiThreshold.doubleValue = -55
            selectedAPIModel = .application
            apiEnable.state = .off
            apiImprove.state = .off
            apiPortField.stringValue = "8790"
            refreshAPI()
        case "hotkeys":
            stopOnEnterCheck.state = .off
            cancelOnEscapeCheck.state = .off
            pauseOnSpaceCheck.state = .on
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
            summaryText.string = DefaultPrompts.summary
            improveEnabledCheck.state = .on
            promptTestLabel?.stringValue = ""
            improveTestLabel?.stringValue = ""
            summaryTestLabel?.stringValue = ""
            updateAIProviderState()
        case "models":
            previewControls.options = RecognitionPreview()
            selectedTechnology = .whisper
            selectedFluidModel = .nemotron
            recognitionValidationMessage = ""
            languagePopup.selectItem(at: 0)
            modelDirs = []
            externalModelPaths = []
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
        if !LocalAPIService.validPort(settings.apiPort) || (settings.apiImproveText && settings.dictationProvider == nil) {
            selectTab("api")
            apiStatus.stringValue = !LocalAPIService.validPort(settings.apiPort)
                ? "Порт должен быть от 1 до 65535; 8798 и 8799 используются движками Runvoice."
                : "Для AI-правки API выберите профиль правки диктовки или отключите AI."
            apiStatus.textColor = .systemOrange
            return
        }
        let apiOnly = !settings.differsOutsideAPI(from: loadedSettings)
            && providerKeys == loadedProviderKeys
            && (launchCheck.state == .on) == loadedLaunchAtLogin
        if apiOnly {
            // Сохраняем только API-поля, не нормализуя остальные настройки на диске.
            let merged = SettingsStore.load().copyingAPI(from: settings)
            SettingsStore.save(merged)
            loadedSettings = settings
            onAPISettingsSaved?()
            allowClose = true; window?.close(); allowClose = false
            return
        }
        let changedTechnology = settings.recognitionTechnology != loadedSettings.recognitionTechnology
        let changedWhisper = settings.whisperModelPath != loadedSettings.whisperModelPath
        let changedFluid = settings.fluidModel != loadedSettings.fluidModel
        if settings.recognitionTechnology == .fluidAudio, (changedTechnology || changedFluid),
           !FluidModelStore.installed(settings.fluidModel) {
            recognitionValidationMessage = "Сначала скачайте и проверьте выбранную модель FluidAudio."
        } else if ((settings.recognitionTechnology == .whisper && changedTechnology)
                    || (changedWhisper && !settings.whisperModelPath.isEmpty)),
                  WhisperModelStore.activeModel(settings: settings) == nil {
            recognitionValidationMessage = "Сначала скачайте и выберите доступную модель Whisper."
        } else { recognitionValidationMessage = "" }
        if !recognitionValidationMessage.isEmpty {
            selectTab("models")
            refreshModels()
            return
        }

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
        label.toolTip = value
        return SettingsDataTable.padded(label)
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
        guard let field = obj.object as? NSTextField else { return }
        if field === historySearch { reloadHistory() }
        if field === apiPortField { refreshAPI() }
    }
}
