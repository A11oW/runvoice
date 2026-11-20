import AppKit
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Окно расшифровки аудиофайла

final class AudioTranscribeWindow: NSWindowController, NSWindowDelegate {
    private enum Mode: Int {
        case transcription = 0
        case summary = 1
    }

    private enum DisplayedKind {
        case transcript
        case summary
    }

    private enum FailedOperation {
        case transcription
        case summary
    }

    private let runner: DictationRunner

    private let chooseButton = NSButton()
    private let cancelButton = NSButton()
    private let copyButton = NSButton()
    private let clearButton = NSButton()
    private let summaryButton = NSButton()
    private let saveButton = NSButton()
    private let openEditorButton = NSButton()
    private let retryButton = NSButton()
    private let logButton = NSButton()
    private let fileLabel = NSTextField(labelWithString: "Файл не выбран")
    private let fileMetaLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "Выберите аудиофайл или перетащите его в окно.")
    private let countLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private var textView = NSTextView()
    private let dropView = AudioDropView()
    private var dropHeight: NSLayoutConstraint!
    private var fileInfoStack: NSStackView!

    private let modePopup = NSPopUpButton()
    private let modeLabel = NSTextField(labelWithString: "Режим:")
    private let modelBadge = BadgeView()
    private let languageBadge = BadgeView()
    private let aiBadge = BadgeView()
    private let presetPopup = NSPopUpButton()
    private let promptToggle = NSButton()
    private let promptContent = NSStackView()
    private var promptView = NSTextView()
    private let promptCountLabel = NSTextField(labelWithString: "")
    private let promptResetButton = NSButton()
    private let promptSaveButton = NSButton()
    private var promptContainer: NSStackView!
    private var promptExpanded = false

    private let promptLimit = 4_000
    private let summaryPresetTexts = [
        "Сделай краткое саммари в 3–5 предложениях. Оставь только главные мысли и итог.",
        "Сделай саммари в виде маркированного списка из 5–10 пунктов. Один пункт — одна мысль.",
        "Выдели решения, задачи, сроки и ответственных. Если чего-то нет — не придумывай. Верни структурированный список.",
    ]
    private var mode: Mode = .transcription
    private var displayedKind: DisplayedKind = .transcript
    private var transcriptText = ""
    private var summaryText = ""
    private var summarySource = ""
    private var summaryPromptUsed = ""

    private var process: Process?
    private var currentDirectory: URL?
    private var runToken = UUID()
    private var summaryToken = UUID()
    private var isRunning = false
    private var isSummarizing = false
    private var startedAt: Date?
    private var elapsedTimer: Timer?
    private var busyPrefix = ""
    private var textObserver: NSObjectProtocol?
    private var promptObserver: NSObjectProtocol?
    private let searchField = NSSearchField()
    private let searchCountLabel = NSTextField(labelWithString: "")
    private let searchPrevButton = NSButton()
    private let searchNextButton = NSButton()
    private var searchRow: NSStackView!
    private var searchHeight: NSLayoutConstraint!
    private var searchMatches: [NSRange] = []
    private var searchIndex = 0
    private var failedOperation: FailedOperation?
    private var lastFileURL: URL?
    private var isApplyingPreset = false

    var onOpenSettings: (() -> Void)?

    private var isBusy: Bool { isRunning || isSummarizing }

    init(runner: DictationRunner) {
        self.runner = runner
        let window = TranscribeWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Runvoice — Расшифровка аудио"
        window.minSize = NSSize(width: 680, height: 680)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        window.onCommandF = { [weak self] in self?.toggleSearch() }
        window.onEscape = { [weak self] in
            guard let self, !self.searchRow.isHidden else { return false }
            self.toggleSearch()
            return true
        }
        mode = Mode(rawValue: UserDefaults.standard.integer(forKey: "transcribeMode")) ?? .transcription
        build()
        textObserver = NotificationCenter.default.addObserver(
            forName: NSText.didChangeNotification, object: textView, queue: .main
        ) { [weak self] _ in
            self?.transcriptDidChange()
        }
        promptObserver = NotificationCenter.default.addObserver(
            forName: NSText.didChangeNotification, object: promptView, queue: .main
        ) { [weak self] _ in
            self?.promptDidChange()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let textObserver {
            NotificationCenter.default.removeObserver(textObserver)
        }
        if let promptObserver {
            NotificationCenter.default.removeObserver(promptObserver)
        }
    }

    func show() {
        normalizeModeForContent()
        refreshBadges()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Обновляет бейджи после сохранения настроек.
    func refreshSettings() {
        refreshBadges()
        updateSummaryButton()
    }

    /// Запуск расшифровки извне — используется отладочным флагом `--transcribe-file`.
    func transcribe(url: URL) {
        start(url)
    }

    /// Заполняет окно примером для скриншота в документации.
    func showSample(text: String, fileName: String) {
        mode = .transcription
        modePopup.selectItem(at: Mode.transcription.rawValue)
        updateModeUI()
        fileLabel.stringValue = fileName
        fileLabel.toolTip = fileName
        fileMetaLabel.stringValue = "12:34 · 38 МБ · M4A"
        refreshBadges()
        transcriptText = text
        summaryText = ""
        summarySource = ""
        summaryPromptUsed = ""
        displayedKind = .transcript
        textView.string = text
        setStatus("Готово", color: .secondaryLabelColor)
        updateCount()
    }

    /// Пример окна в режиме саммари для скриншота.
    func showSummarySample(transcript: String, summary: String,
                           fileName: String, prompt: String) {
        mode = .summary
        modePopup.selectItem(at: Mode.summary.rawValue)
        promptExpanded = true
        promptContent.isHidden = false
        promptToggle.title = "Промпт саммари ▾"
        promptView.string = prompt
        transcriptText = transcript
        summaryText = summary
        summarySource = transcript
        summaryPromptUsed = prompt
        displayedKind = .summary
        fileLabel.stringValue = fileName
        fileLabel.toolTip = fileName
        fileMetaLabel.stringValue = "12:34 · 38 МБ · M4A"
        refreshBadges()
        textView.string = summary
        updateModeUI()
        updatePromptState()
        syncPresetSelection()
        setStatus("Саммари готово", color: .secondaryLabelColor)
        updateCount()
    }

    func windowWillClose(_ notification: Notification) {
        cancelCurrent()
        removeCurrentDirectory()
    }

    // MARK: - Интерфейс

    private func build() {
        guard let content = window?.contentView else { return }

        modeLabel.font = .systemFont(ofSize: 12)
        modeLabel.textColor = .secondaryLabelColor

        modePopup.addItems(withTitles: ["Транскрибация", "Саммари"])
        modePopup.selectItem(at: mode.rawValue)
        modePopup.target = self
        modePopup.action = #selector(modeChanged)
        modePopup.widthAnchor.constraint(equalToConstant: 170).isActive = true

        let modeRow = NSStackView(views: [modeLabel, modePopup])
        modeRow.orientation = .horizontal
        modeRow.alignment = .centerY
        modeRow.spacing = 8

        let badgesSpacer = NSView()
        badgesSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let badgesRow = NSStackView(views: [modelBadge, languageBadge, aiBadge, badgesSpacer])
        badgesRow.orientation = .horizontal
        badgesRow.alignment = .centerY
        badgesRow.spacing = 6

        chooseButton.title = "Выбрать аудиофайл…"
        chooseButton.target = self
        chooseButton.action = #selector(chooseFile)
        chooseButton.bezelStyle = .rounded
        chooseButton.setAccessibilityLabel("Выбрать аудиофайл")

        cancelButton.title = "Отменить"
        cancelButton.target = self
        cancelButton.action = #selector(cancelCurrent)
        cancelButton.bezelStyle = .rounded
        cancelButton.isHidden = true

        fileLabel.font = .systemFont(ofSize: 13, weight: .medium)
        fileLabel.textColor = .labelColor
        fileLabel.lineBreakMode = .byTruncatingMiddle
        fileLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        fileLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        fileMetaLabel.font = .systemFont(ofSize: 10)
        fileMetaLabel.textColor = .secondaryLabelColor
        fileMetaLabel.lineBreakMode = .byTruncatingTail

        fileInfoStack = NSStackView(views: [fileLabel, fileMetaLabel])
        fileInfoStack.orientation = .vertical
        fileInfoStack.alignment = .leading
        fileInfoStack.spacing = 2
        fileInfoStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let top = NSStackView(views: [chooseButton, fileInfoStack, cancelButton])
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = 10
        top.detachesHiddenViews = true

        promptToggle.title = "Промпт саммари ▸"
        promptToggle.bezelStyle = .inline
        promptToggle.target = self
        promptToggle.action = #selector(togglePrompt)

        promptCountLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        promptCountLabel.textColor = .secondaryLabelColor
        promptCountLabel.setContentHuggingPriority(.required, for: .horizontal)

        let promptHeaderSpacer = NSView()
        promptHeaderSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let promptHeader = NSStackView(views: [promptToggle, promptHeaderSpacer, promptCountLabel])
        promptHeader.orientation = .horizontal
        promptHeader.alignment = .centerY
        promptHeader.spacing = 8

        let promptScroll = NSTextView.scrollableTextView()
        promptScroll.hasVerticalScroller = true
        promptScroll.autohidesScrollers = true
        promptScroll.borderType = .bezelBorder
        promptScroll.heightAnchor.constraint(equalToConstant: 76).isActive = true

        promptView = promptScroll.documentView as! NSTextView
        promptView.isRichText = false
        promptView.font = .systemFont(ofSize: 12)
        promptView.textContainerInset = NSSize(width: 6, height: 6)
        promptView.setAccessibilityLabel("Промпт саммари")

        let promptHint = NSTextField(labelWithString:
            "Пустое поле — промпт из настроек. Кастомный промпт заменяет встроенный для итогового саммари.")
        promptHint.font = .systemFont(ofSize: 10)
        promptHint.textColor = .secondaryLabelColor
        promptHint.lineBreakMode = .byWordWrapping
        promptHint.maximumNumberOfLines = 2

        promptResetButton.title = "Сбросить к настройкам"
        promptResetButton.target = self
        promptResetButton.action = #selector(resetPrompt)
        promptResetButton.bezelStyle = .rounded

        promptSaveButton.title = "Сохранить по умолчанию"
        promptSaveButton.target = self
        promptSaveButton.action = #selector(savePrompt)
        promptSaveButton.bezelStyle = .rounded

        let promptButtons = NSStackView(views: [promptResetButton, promptSaveButton])
        promptButtons.orientation = .horizontal
        promptButtons.spacing = 8

        promptContent.orientation = .vertical
        promptContent.alignment = .leading
        promptContent.spacing = 6
        promptContent.detachesHiddenViews = true
        promptContent.addArrangedSubview(promptScroll)
        promptContent.addArrangedSubview(promptHint)
        promptContent.addArrangedSubview(promptButtons)
        promptContent.isHidden = true
        for view in [promptScroll, promptHint, promptButtons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: promptContent.widthAnchor).isActive = true
        }

        let presetLabel = NSTextField(labelWithString: "Пресет:")
        presetLabel.font = .systemFont(ofSize: 11)
        presetLabel.textColor = .secondaryLabelColor
        presetPopup.addItems(withTitles: ["По умолчанию", "Кратко", "Тезисы", "Задачи", "Свой…"])
        presetPopup.target = self
        presetPopup.action = #selector(presetChanged)
        presetPopup.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let presetRow = NSStackView(views: [presetLabel, presetPopup])
        presetRow.orientation = .horizontal
        presetRow.alignment = .centerY
        presetRow.spacing = 8

        promptContainer = NSStackView(views: [presetRow, promptHeader, promptContent])
        promptContainer.orientation = .vertical
        promptContainer.alignment = .leading
        promptContainer.spacing = 8
        promptContainer.detachesHiddenViews = true
        promptContainer.isHidden = true

        for view in [presetRow, promptHeader, promptContent] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: promptContainer.widthAnchor).isActive = true
        }

        let headerStack = NSStackView(views: [modeRow, badgesRow, top, promptContainer])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 10
        headerStack.detachesHiddenViews = true
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(headerStack)

        for view in [modeRow, badgesRow, top, promptContainer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: headerStack.widthAnchor).isActive = true
        }

        dropView.onDrop = { [weak self] url in
            self?.start(url)
        }
        dropView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(dropView)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 2
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        retryButton.title = "Повторить"
        retryButton.target = self
        retryButton.action = #selector(retryLastOperation)
        retryButton.bezelStyle = .rounded
        retryButton.isHidden = true

        logButton.title = "Открыть лог"
        logButton.target = self
        logButton.action = #selector(openDictationLog)
        logButton.bezelStyle = .rounded
        logButton.isHidden = true

        let statusRow = NSStackView(views: [spinner, statusLabel, retryButton, logButton])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 8
        statusRow.detachesHiddenViews = true
        statusRow.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(statusRow)

        searchField.placeholderString = "Поиск по тексту"
        searchField.delegate = self
        searchField.widthAnchor.constraint(equalToConstant: 240).isActive = true

        searchPrevButton.title = "‹"
        searchPrevButton.target = self
        searchPrevButton.action = #selector(previousMatch)
        searchPrevButton.bezelStyle = .rounded
        searchPrevButton.widthAnchor.constraint(equalToConstant: 30).isActive = true

        searchNextButton.title = "›"
        searchNextButton.target = self
        searchNextButton.action = #selector(nextMatch)
        searchNextButton.bezelStyle = .rounded
        searchNextButton.widthAnchor.constraint(equalToConstant: 30).isActive = true

        searchCountLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        searchCountLabel.textColor = .secondaryLabelColor
        searchCountLabel.setContentHuggingPriority(.required, for: .horizontal)

        searchRow = NSStackView(views: [searchField, searchPrevButton,
                                        searchNextButton, searchCountLabel])
        searchRow.orientation = .horizontal
        searchRow.alignment = .centerY
        searchRow.spacing = 6
        searchRow.isHidden = true
        searchRow.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(searchRow)
        searchHeight = searchRow.heightAnchor.constraint(equalToConstant: 0)
        searchHeight.isActive = true

        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        textView = scroll.documentView as! NSTextView
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.setAccessibilityLabel("Распознанный текст")
        content.addSubview(scroll)

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        summaryButton.title = "Сделать саммари"
        summaryButton.target = self
        summaryButton.action = #selector(makeSummary)
        summaryButton.bezelStyle = .rounded
        summaryButton.isHidden = true

        saveButton.title = "Сохранить…"
        saveButton.target = self
        saveButton.action = #selector(saveText)
        saveButton.bezelStyle = .rounded

        openEditorButton.title = "В TextEdit"
        openEditorButton.target = self
        openEditorButton.action = #selector(openInTextEdit)
        openEditorButton.bezelStyle = .rounded

        clearButton.title = "Очистить"
        clearButton.target = self
        clearButton.action = #selector(clearText)
        clearButton.bezelStyle = .rounded

        copyButton.title = "Копировать"
        copyButton.target = self
        copyButton.action = #selector(copyText)
        copyButton.bezelStyle = .rounded

        let bottom = NSStackView(views: [countLabel, spacer, summaryButton,
                                         saveButton, openEditorButton, copyButton, clearButton])
        bottom.orientation = .horizontal
        bottom.alignment = .centerY
        bottom.spacing = 8
        bottom.detachesHiddenViews = true
        bottom.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(bottom)

        dropHeight = dropView.heightAnchor.constraint(equalToConstant: 76)
        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            headerStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            headerStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            dropView.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 12),
            dropView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            dropView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            dropHeight,

            statusRow.topAnchor.constraint(equalTo: dropView.bottomAnchor, constant: 12),
            statusRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            statusRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            searchRow.topAnchor.constraint(equalTo: statusRow.bottomAnchor, constant: 6),
            searchRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            searchRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            scroll.topAnchor.constraint(equalTo: searchRow.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),

            bottom.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            bottom.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            bottom.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
        ])

        promptView.string = SettingsStore.load().promptSummary
        normalizeModeForContent()
        updateModeUI()
        updatePromptState()
        updateCount()
        refreshBadges()
    }

    private func updateModeUI() {
        let summaryMode = mode == .summary
        chooseButton.isHidden = summaryMode
        fileInfoStack.isHidden = summaryMode
        dropView.isHidden = summaryMode
        dropHeight.constant = summaryMode ? 0 : 76
        dropView.acceptsDrop = !summaryMode && !isBusy
        promptContainer.isHidden = !summaryMode
        summaryButton.isHidden = !summaryMode
        modePopup.item(at: Mode.summary.rawValue)?.isEnabled =
            !transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        promptToggle.title = promptExpanded ? "Промпт саммари ▾" : "Промпт саммари ▸"
        updateSummaryButton()
    }

    private func normalizeModeForContent() {
        guard mode == .summary,
              transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        mode = .transcription
        modePopup.selectItem(at: Mode.transcription.rawValue)
        UserDefaults.standard.set(mode.rawValue, forKey: "transcribeMode")
        updateModeUI()
    }

    // MARK: - Выбор файла

    @objc private func chooseFile() {
        guard !isBusy, let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio, .movie]
        panel.message = "Выберите аудиофайл для расшифровки"
        panel.prompt = "Расшифровать"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.start(url)
        }
    }

    private func start(_ url: URL) {
        guard !isBusy else { return }
        if mode != .transcription {
            mode = .transcription
            modePopup.selectItem(at: Mode.transcription.rawValue)
            UserDefaults.standard.set(mode.rawValue, forKey: "transcribeMode")
            updateModeUI()
        }
        lastFileURL = url
        clearFailure()
        removeCurrentDirectory()

        let token = UUID()
        runToken = token
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunvoiceTranscribe-\(token.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                               ofItemAtPath: directory.path)
        currentDirectory = directory

        fileLabel.stringValue = url.lastPathComponent
        fileLabel.toolTip = url.path
        updateFileMetadata(url)
        transcriptText = ""
        summaryText = ""
        summarySource = ""
        summaryPromptUsed = ""
        displayedKind = .transcript
        textView.string = ""
        isRunning = true
        setBusy(true)
        startElapsed(prefix: "Распознаю аудио…")
        updateCount()

        let process = runner.transcribe(file: url, outputDirectory: directory) { [weak self] result in
            guard let self, self.runToken == token else { return }
            let elapsed = self.elapsedText()
            self.process = nil
            self.isRunning = false
            self.setBusy(false)
            self.stopElapsed()
            switch result {
            case .success(let text):
                self.clearFailure()
                self.transcriptText = text
                self.summaryText = ""
                self.summarySource = ""
                self.summaryPromptUsed = ""
                self.displayedKind = .transcript
                self.textView.string = text
                if self.mode == .summary {
                    self.setStatus("Готово · \(elapsed). Нажмите «Сделать саммари».",
                                   color: .secondaryLabelColor)
                } else {
                    self.setStatus("Готово · \(elapsed)", color: .secondaryLabelColor)
                }
                self.window?.makeFirstResponder(self.textView)
                Log.write("import: готово, chars=\(text.count)")
            case .failure(let error):
                self.showFailure(error.localizedDescription, operation: .transcription)
            }
            self.updateCount()
            self.removeCurrentDirectory()
        }
        self.process = process
    }

    // MARK: - Режим и промпт

    @objc private func modeChanged() {
        guard !isBusy else {
            modePopup.selectItem(at: mode.rawValue)
            return
        }
        let newMode = Mode(rawValue: modePopup.indexOfSelectedItem) ?? .transcription
        if newMode != mode {
            mode = newMode
            UserDefaults.standard.set(mode.rawValue, forKey: "transcribeMode")
            updateModeUI()
            refreshModeContent()
        }
    }

    private func refreshModeContent() {
        guard !transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            displayedKind = .transcript
            textView.string = ""
            setStatus("Выберите аудиофайл или перетащите его в окно.",
                      color: .secondaryLabelColor)
            updateCount()
            return
        }

        if mode == .summary, summaryIsCurrent {
            displaySummary()
            setStatus("Саммари готово", color: .secondaryLabelColor)
        } else {
            displayTranscription()
            if mode == .summary {
                setStatus("Нажмите «Сделать саммари».", color: .secondaryLabelColor)
            } else {
                setStatus("Готово", color: .secondaryLabelColor)
            }
        }
        updateCount()
    }

    @objc private func togglePrompt() {
        promptExpanded.toggle()
        promptContent.isHidden = !promptExpanded
        promptToggle.title = promptExpanded ? "Промпт саммари ▾" : "Промпт саммари ▸"
    }

    @objc private func resetPrompt() {
        promptView.string = SettingsStore.load().promptSummary
        setStatus("Промпт саммари сброшен к настройкам", color: .secondaryLabelColor)
        updatePromptState()
        syncPresetSelection()
    }

    @objc private func savePrompt() {
        guard !isBusy, promptView.string.count <= promptLimit else { return }
        var settings = SettingsStore.load()
        settings.promptSummary = promptView.string
        SettingsStore.save(settings)
        setStatus("Промпт саммари сохранён в настройках", color: .secondaryLabelColor)
        Log.write("summary: prompt saved chars=\(promptView.string.count)")
        updateSummaryButton()
        syncPresetSelection()
    }

    private func currentPrompt() -> String {
        let field = promptView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !field.isEmpty { return promptView.string }
        let stored = SettingsStore.load().promptSummary
        return stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? DefaultPrompts.summary
            : stored
    }

    private var summaryIsCurrent: Bool {
        guard !summaryText.isEmpty else { return false }
        return summarySource == transcriptText && summaryPromptUsed == currentPrompt()
    }

    private func promptDidChange() {
        updatePromptState()
        if !isApplyingPreset { syncPresetSelection() }
        if mode == .summary, !summaryText.isEmpty, !summaryIsCurrent {
            setStatus("Промпт или текст изменены — нажмите «Сделать саммари».",
                      color: .secondaryLabelColor)
        }
    }

    private func updatePromptState() {
        let count = promptView.string.count
        promptCountLabel.stringValue = "\(count)/\(promptLimit)"
        promptCountLabel.textColor = count > promptLimit ? .systemRed : .secondaryLabelColor
        promptSaveButton.isEnabled = !isBusy && count <= promptLimit
        promptResetButton.isEnabled = !isBusy
        updateSummaryButton()
    }

    private func updateSummaryButton() {
        guard mode == .summary else {
            summaryButton.isHidden = true
            return
        }
        summaryButton.isHidden = false
        let hasText = !transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        summaryButton.isEnabled = !isBusy && hasText && promptView.string.count <= promptLimit
        summaryButton.title = summaryIsCurrent ? "Обновить саммари" : "Сделать саммари"
        summaryButton.toolTip = promptView.string.count > promptLimit
            ? "Промпт длиннее \(promptLimit) символов"
            : nil
    }

    // MARK: - Саммари

    @objc private func makeSummary() {
        guard !isBusy, mode == .summary else { return }
        let source = transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else {
            setStatus("Сначала распознайте аудиофайл.", color: .systemOrange)
            return
        }
        guard promptView.string.count <= promptLimit else {
            setStatus("Промпт саммари слишком длинный (макс. \(promptLimit) символов).",
                      color: .systemRed)
            return
        }

        let settings = SettingsStore.load()
        guard let provider = settings.improveProvider else {
            setStatus("Не выбран AI-провайдер для саммари.", color: .systemOrange)
            let alert = NSAlert()
            alert.messageText = "Не выбран AI-провайдер для саммари"
            alert.informativeText = "Выберите провайдера для улучшения текста в «Настройки → Постобработка»."
            alert.addButton(withTitle: "Открыть настройки")
            alert.addButton(withTitle: "Отмена")
            if alert.runModal() == .alertFirstButtonReturn {
                onOpenSettings?()
            }
            return
        }

        let prompt = currentPrompt()
        clearFailure()
        let token = UUID()
        summaryToken = token
        isSummarizing = true
        setBusy(true)
        startElapsed(prefix: "Делаю саммари…")
        Log.write("summary: запуск chars=\(transcriptText.count) promptChars=\(prompt.count) provider=\(provider.displayTitle)")

        SummaryService.summarize(
            text: transcriptText,
            prompt: prompt,
            provider: provider,
            isCancelled: { [weak self] in self?.summaryToken != token },
            onStatus: { [weak self] text in
                guard let self, self.summaryToken == token else { return }
                self.busyPrefix = text
                self.setStatus("\(text) \(self.elapsedText())", color: .secondaryLabelColor)
            },
            completion: { [weak self] result in
                guard let self, self.summaryToken == token else { return }
                let elapsed = self.elapsedText()
                self.isSummarizing = false
                self.setBusy(false)
                self.stopElapsed()
                switch result {
                case .success(let summary):
                    self.clearFailure()
                    self.summaryText = summary
                    self.summarySource = self.transcriptText
                    self.summaryPromptUsed = prompt
                    self.displaySummary()
                    self.setStatus("Саммари готово · \(elapsed)", color: .secondaryLabelColor)
                    Log.write("summary: готово chars=\(summary.count)")
                case .failure(let error):
                    self.displayTranscription()
                    self.showFailure("Не удалось сделать саммари: \(error.localizedDescription)",
                                     operation: .summary)
                }
                self.updateCount()
            })
    }

    // MARK: - Отмена и результат

    @objc private func cancelCurrent() {
        if isRunning {
            runToken = UUID()
            process?.terminate()
            process = nil
            isRunning = false
            setBusy(false)
            stopElapsed()
            clearFailure()
            setStatus("Отменено", color: .secondaryLabelColor)
            updateCount()
            Log.write("import: отменено пользователем")
            removeCurrentDirectory()
            return
        }
        guard isSummarizing else { return }
        summaryToken = UUID()
        isSummarizing = false
        setBusy(false)
        stopElapsed()
        if mode == .summary, summaryIsCurrent {
            displaySummary()
        } else {
            displayTranscription()
        }
        clearFailure()
        setStatus("Саммари отменено", color: .secondaryLabelColor)
        updateCount()
        Log.write("summary: отменено пользователем")
    }

    @objc private func clearText() {
        guard !isBusy else { return }
        transcriptText = ""
        summaryText = ""
        summarySource = ""
        summaryPromptUsed = ""
        lastFileURL = nil
        fileLabel.stringValue = "Файл не выбран"
        fileLabel.toolTip = nil
        fileMetaLabel.stringValue = ""
        displayedKind = .transcript
        textView.string = ""
        clearFailure()
        mode = .transcription
        modePopup.selectItem(at: Mode.transcription.rawValue)
        UserDefaults.standard.set(mode.rawValue, forKey: "transcribeMode")
        updateModeUI()
        setStatus("Выберите аудиофайл или перетащите его в окно.",
                  color: .secondaryLabelColor)
        updateCount()
    }

    @objc private func copyText() {
        let text = textView.string
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        setStatus("Скопировано в буфер обмена", color: .secondaryLabelColor)
    }

    // MARK: - Сохранение и открытие

    @objc private func saveText() {
        guard !isBusy, !textView.string.isEmpty, let window else { return }
        let panel = NSSavePanel()
        var types: [UTType] = [.plainText]
        if let markdown = UTType(filenameExtension: "md") { types.append(markdown) }
        panel.allowedContentTypes = types
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultExportName()
        panel.message = "Сохранить результат расшифровки"
        panel.isExtensionHidden = false

        let formatLabel = NSTextField(labelWithString: "Формат:")
        formatLabel.font = .systemFont(ofSize: 11)
        formatLabel.textColor = .secondaryLabelColor
        let formatPopup = NSPopUpButton()
        formatPopup.addItems(withTitles: ["Текст (.txt)", "Markdown (.md)"])
        formatPopup.widthAnchor.constraint(equalToConstant: 170).isActive = true
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 38))
        let accessoryStack = NSStackView(views: [formatLabel, formatPopup])
        accessoryStack.orientation = .horizontal
        accessoryStack.alignment = .centerY
        accessoryStack.spacing = 8
        accessoryStack.translatesAutoresizingMaskIntoConstraints = false
        accessory.addSubview(accessoryStack)
        NSLayoutConstraint.activate([
            accessoryStack.leadingAnchor.constraint(equalTo: accessory.leadingAnchor, constant: 16),
            accessoryStack.centerYAnchor.constraint(equalTo: accessory.centerYAnchor),
        ])
        panel.accessoryView = accessory

        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, var url = panel.url else { return }
            let extensionName = formatPopup.indexOfSelectedItem == 1 ? "md" : "txt"
            if url.pathExtension.lowercased() != extensionName {
                url = url.deletingPathExtension().appendingPathExtension(extensionName)
            }
            do {
                try self.textView.string.write(to: url, atomically: true, encoding: .utf8)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                       ofItemAtPath: url.path)
                self.clearFailure()
                self.setStatus("Сохранено: \(url.lastPathComponent)", color: .secondaryLabelColor)
                Log.write("import: сохранено \(url.lastPathComponent), chars=\(self.textView.string.count)")
            } catch {
                self.showFailure("Не удалось сохранить: \(error.localizedDescription)", operation: nil)
            }
        }
    }

    @objc private func openInTextEdit() {
        guard !isBusy, !textView.string.isEmpty else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Runvoice-\(UUID().uuidString).txt")
        do {
            try textView.string.write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: url.path)
            guard let app = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.apple.TextEdit") else {
                showFailure("TextEdit не найден", operation: nil)
                return
            }
            NSWorkspace.shared.open([url], withApplicationAt: app,
                                    configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let error {
                        self.showFailure("Не удалось открыть TextEdit: \(error.localizedDescription)",
                                         operation: nil)
                    } else {
                        self.clearFailure()
                        self.setStatus("Открыто в TextEdit", color: .secondaryLabelColor)
                    }
                }
            }
        } catch {
            showFailure("Не удалось открыть текст: \(error.localizedDescription)", operation: nil)
        }
    }

    private func defaultExportName() -> String {
        let base: String
        if let lastFileURL {
            base = lastFileURL.deletingPathExtension().lastPathComponent
        } else if fileLabel.stringValue != "Файл не выбран" {
            base = (fileLabel.stringValue as NSString).deletingPathExtension
        } else {
            base = "расшифровка"
        }
        let suffix = displayedKind == .summary ? "-саммари" : "-транскрипт"
        return "\(base)\(suffix).txt"
    }

    // MARK: - Поиск

    @objc private func toggleSearch() {
        let show = searchRow.isHidden
        searchRow.isHidden = !show
        searchHeight.constant = show ? 24 : 0
        if show {
            window?.makeFirstResponder(searchField)
            updateSearch()
        } else {
            searchField.stringValue = ""
            searchMatches = []
            searchIndex = 0
            searchCountLabel.stringValue = ""
            window?.makeFirstResponder(textView)
        }
    }

    private func updateSearch() {
        let query = searchField.stringValue
        searchMatches.removeAll()
        searchIndex = 0
        guard !query.isEmpty else {
            searchCountLabel.stringValue = ""
            return
        }
        let source = textView.string as NSString
        var location = 0
        while location < source.length {
            let range = NSRange(location: location, length: source.length - location)
            let found = source.range(of: query, options: [.caseInsensitive, .diacriticInsensitive],
                                     range: range)
            if found.location == NSNotFound { break }
            searchMatches.append(found)
            location = found.location + max(found.length, 1)
        }
        searchPrevButton.isEnabled = !searchMatches.isEmpty && !isBusy
        searchNextButton.isEnabled = !searchMatches.isEmpty && !isBusy
        if searchMatches.isEmpty {
            searchCountLabel.stringValue = "Нет совпадений"
        } else {
            selectSearchMatch()
        }
    }

    private func selectSearchMatch() {
        guard !searchMatches.isEmpty else {
            searchCountLabel.stringValue = "Нет совпадений"
            return
        }
        searchIndex = min(max(0, searchIndex), searchMatches.count - 1)
        let range = searchMatches[searchIndex]
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        searchCountLabel.stringValue = "\(searchIndex + 1) из \(searchMatches.count)"
    }

    @objc private func previousMatch() {
        guard !searchMatches.isEmpty else { return }
        searchIndex = (searchIndex - 1 + searchMatches.count) % searchMatches.count
        selectSearchMatch()
    }

    @objc private func nextMatch() {
        guard !searchMatches.isEmpty else { return }
        searchIndex = (searchIndex + 1) % searchMatches.count
        selectSearchMatch()
    }

    // MARK: - Пресеты промпта

    @objc private func presetChanged() {
        guard !isBusy else { syncPresetSelection(); return }
        let index = presetPopup.indexOfSelectedItem
        if index == 4 {
            expandPrompt()
            window?.makeFirstResponder(promptView)
            setStatus("Введите свой промпт саммари", color: .secondaryLabelColor)
            return
        }
        isApplyingPreset = true
        if index == 0 {
            promptView.string = SettingsStore.load().promptSummary
        } else if index - 1 < summaryPresetTexts.count {
            promptView.string = summaryPresetTexts[index - 1]
        }
        isApplyingPreset = false
        syncPresetSelection()
        updatePromptState()
        setStatus("Пресет: \(presetPopup.titleOfSelectedItem ?? "По умолчанию")",
                  color: .secondaryLabelColor)
    }

    private func expandPrompt() {
        promptExpanded = true
        promptContent.isHidden = false
        promptToggle.title = "Промпт саммари ▾"
    }

    private func syncPresetSelection() {
        let value = promptView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            presetPopup.selectItem(at: 0)
            return
        }
        let stored = SettingsStore.load().promptSummary
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !stored.isEmpty, value == stored {
            presetPopup.selectItem(at: 0)
            return
        }
        for (index, preset) in summaryPresetTexts.enumerated()
        where value == preset.trimmingCharacters(in: .whitespacesAndNewlines) {
            presetPopup.selectItem(at: index + 1)
            return
        }
        presetPopup.selectItem(at: 4)
    }

    // MARK: - Ошибки

    private func showFailure(_ message: String, operation: FailedOperation?) {
        setStatus(message, color: .systemRed)
        failedOperation = operation
        retryButton.isHidden = operation == nil
        logButton.isHidden = false
        let prefix = operation == .summary ? "summary" : "import"
        Log.write("\(prefix): ошибка \(message)")
    }

    private func clearFailure() {
        failedOperation = nil
        retryButton.isHidden = true
        logButton.isHidden = true
    }

    @objc private func retryLastOperation() {
        guard !isBusy, let operation = failedOperation else { return }
        clearFailure()
        switch operation {
        case .transcription:
            if let lastFileURL {
                start(lastFileURL)
            } else {
                setStatus("Файл не выбран", color: .systemOrange)
            }
        case .summary:
            makeSummary()
        }
    }

    @objc private func openDictationLog() {
        if !FileManager.default.fileExists(atPath: Paths.log.path) {
            FileManager.default.createFile(atPath: Paths.log.path, contents: nil)
        }
        NSWorkspace.shared.open(Paths.log)
    }

    // MARK: - Бейджи и метаданные

    private func refreshBadges() {
        let settings = SettingsStore.load()
        let model = WhisperModelStore.activeModel(settings: settings)
        let modelTitle = model?.catalogModel?.title ?? model?.fileName
        modelBadge.set(text: "Whisper · \(modelTitle ?? "модель не выбрана")",
                       tone: model == nil ? .warning : .neutral)
        modelBadge.toolTip = model?.path
        languageBadge.set(text: "Язык: \(languageTitle(settings.language))", tone: .neutral)
        languageBadge.toolTip = settings.language
        if let provider = settings.improveProvider {
            aiBadge.set(text: "AI: \(provider.displayTitle)", tone: .neutral)
            aiBadge.toolTip = "\(provider.kind.rawValue) · \(provider.model)"
        } else {
            aiBadge.set(text: "AI: не настроен", tone: .warning)
            aiBadge.toolTip = "Выберите профиль для улучшения в «Постобработке»"
        }
    }

    private func languageTitle(_ value: String) -> String {
        switch value.lowercased() {
        case "ru": return "RU"
        case "en": return "EN"
        case "auto": return "AUTO"
        default: return value.uppercased()
        }
    }

    private func updateFileMetadata(_ url: URL) {
        var sizeText = ""
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? NSNumber {
            sizeText = ByteCountFormatter.string(fromByteCount: size.int64Value,
                                                 countStyle: .file)
        }
        let ext = url.pathExtension.uppercased()
        let baseParts = [sizeText, ext].filter { !$0.isEmpty }
        fileMetaLabel.stringValue = baseParts.joined(separator: " · ")

        let asset = AVURLAsset(url: url)
        Task { [weak self] in
            guard let duration = try? await asset.load(.duration) else { return }
            let seconds = CMTimeGetSeconds(duration)
            guard let self, seconds.isFinite, seconds > 0, self.lastFileURL == url else { return }
            var parts = [self.durationText(seconds)]
            parts.append(contentsOf: baseParts)
            self.fileMetaLabel.stringValue = parts.joined(separator: " · ")
        }
    }

    private func durationText(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func setBusy(_ busy: Bool) {
        chooseButton.isEnabled = !busy
        dropView.acceptsDrop = !busy && mode == .transcription
        modePopup.isEnabled = !busy
        promptToggle.isEnabled = !busy
        promptView.isEditable = !busy
        textView.isEditable = !busy
        searchField.isEnabled = !busy
        searchPrevButton.isEnabled = !busy && !searchMatches.isEmpty
        searchNextButton.isEnabled = !busy && !searchMatches.isEmpty
        cancelButton.isHidden = !busy
        if busy {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
        updatePromptState()
        updateCount()
    }

    private func setStatus(_ text: String, color: NSColor) {
        statusLabel.stringValue = text
        statusLabel.textColor = color
    }

    private func transcriptDidChange() {
        guard !isBusy else {
            updateCount()
            return
        }
        if displayedKind == .summary {
            summaryText = textView.string
        } else {
            transcriptText = textView.string
        }
        updateCount()
        if !searchRow.isHidden { updateSearch() }
    }

    private func displayTranscription() {
        displayedKind = .transcript
        textView.string = transcriptText
        updateCount()
        if !searchRow.isHidden { updateSearch() }
    }

    private func displaySummary() {
        displayedKind = .summary
        textView.string = summaryText
        updateCount()
        if !searchRow.isHidden { updateSearch() }
    }

    private func updateCount() {
        let text = textView.string
        let count = text.count
        let prefix = displayedKind == .summary && mode == .summary ? "Саммари · " : ""
        countLabel.stringValue = count == 0 ? "" : "\(prefix)\(count) символов"
        copyButton.isEnabled = count > 0
        saveButton.isEnabled = count > 0 && !isBusy
        openEditorButton.isEnabled = count > 0 && !isBusy
        clearButton.isEnabled = count > 0 && !isBusy
        modePopup.item(at: Mode.summary.rawValue)?.isEnabled =
            !transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        updateSummaryButton()
    }

    private func startElapsed(prefix: String) {
        busyPrefix = prefix
        startedAt = Date()
        elapsedTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateElapsed()
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
        setStatus(prefix, color: .secondaryLabelColor)
    }

    private func stopElapsed() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        startedAt = nil
        busyPrefix = ""
    }

    private func updateElapsed() {
        guard isBusy, !busyPrefix.isEmpty else { return }
        setStatus("\(busyPrefix) \(elapsedText())", color: .secondaryLabelColor)
    }

    private func elapsedText() -> String {
        guard let startedAt else { return "0:00" }
        let seconds = max(0, Int(Date().timeIntervalSince(startedAt)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func removeCurrentDirectory() {
        guard let directory = currentDirectory else { return }
        currentDirectory = nil
        try? FileManager.default.removeItem(at: directory)
    }
}

final class TranscribeWindow: NSWindow {
    var onCommandF: (() -> Void)?
    var onEscape: (() -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "f" {
            onCommandF?()
            return true
        }
        if event.keyCode == 53, onEscape?() == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

extension AudioTranscribeWindow: NSSearchFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSSearchField) === searchField else { return }
        updateSearch()
    }
}

// MARK: - Бейдж

final class BadgeView: NSView {
    enum Tone {
        case neutral
        case warning
    }

    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    }

    convenience init() {
        self.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        let size = label.intrinsicContentSize
        return NSSize(width: size.width + 16, height: size.height + 6)
    }

    func set(text: String, tone: Tone) {
        label.stringValue = text
        switch tone {
        case .neutral:
            label.textColor = .secondaryLabelColor
            layer?.backgroundColor = NSColor.controlBackgroundColor
                .withAlphaComponent(0.65).cgColor
        case .warning:
            label.textColor = .systemOrange
            layer?.backgroundColor = NSColor.systemOrange
                .withAlphaComponent(0.16).cgColor
        }
        invalidateIntrinsicContentSize()
    }
}

// MARK: - Зона drag & drop

final class AudioDropView: NSView {
    var onDrop: ((URL) -> Void)?
    var acceptsDrop = true {
        didSet { needsDisplay = true }
    }

    private let label = NSTextField(labelWithString:
        "Перетащите аудиофайл сюда\nWAV, MP3, M4A, FLAC, OGG и другие")
    private var highlighted = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        label.alignment = .center
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        if highlighted {
            NSColor.controlAccentColor.withAlphaComponent(0.08).setFill()
            path.fill()
        }
        path.lineWidth = 1.5
        path.setLineDash([6, 4], count: 2, phase: 0)
        NSColor.separatorColor.setStroke()
        path.stroke()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptsDrop else { return [] }
        highlighted = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        highlighted = false
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        acceptsDrop
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        guard acceptsDrop else { return false }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let url = sender.draggingPasteboard
            .readObjects(forClasses: [NSURL.self], options: options)?
            .first as? URL else { return false }
        onDrop?(url)
        return true
    }
}
