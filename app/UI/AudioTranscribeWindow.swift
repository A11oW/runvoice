import AppKit
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

    private let runner: DictationRunner

    private let chooseButton = NSButton()
    private let cancelButton = NSButton()
    private let copyButton = NSButton()
    private let clearButton = NSButton()
    private let summaryButton = NSButton()
    private let fileLabel = NSTextField(labelWithString: "Файл не выбран")
    private let statusLabel = NSTextField(labelWithString: "Выберите аудиофайл или перетащите его в окно.")
    private let countLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private var textView = NSTextView()
    private let dropView = AudioDropView()

    private let modePopup = NSPopUpButton()
    private let modeLabel = NSTextField(labelWithString: "Режим:")
    private let promptToggle = NSButton()
    private let promptContent = NSStackView()
    private var promptView = NSTextView()
    private let promptCountLabel = NSTextField(labelWithString: "")
    private let promptResetButton = NSButton()
    private let promptSaveButton = NSButton()
    private var promptContainer: NSStackView!
    private var promptExpanded = false

    private let promptLimit = 4_000
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

    var onOpenSettings: (() -> Void)?

    private var isBusy: Bool { isRunning || isSummarizing }

    init(runner: DictationRunner) {
        self.runner = runner
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Runvoice — Расшифровка аудио"
        window.minSize = NSSize(width: 640, height: 640)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
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
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
        textView.string = summary
        updateModeUI()
        updatePromptState()
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

        fileLabel.lineBreakMode = .byTruncatingMiddle
        fileLabel.textColor = .secondaryLabelColor
        fileLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        fileLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let top = NSStackView(views: [chooseButton, fileLabel, cancelButton])
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

        promptContainer = NSStackView(views: [promptHeader, promptContent])
        promptContainer.orientation = .vertical
        promptContainer.alignment = .leading
        promptContainer.spacing = 8
        promptContainer.detachesHiddenViews = true
        promptContainer.isHidden = true

        for view in [promptHeader, promptContent] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: promptContainer.widthAnchor).isActive = true
        }

        let headerStack = NSStackView(views: [modeRow, top, promptContainer])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 10
        headerStack.detachesHiddenViews = true
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(headerStack)

        for view in [modeRow, top, promptContainer] as [NSView] {
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

        let statusRow = NSStackView(views: [spinner, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 8
        statusRow.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(statusRow)

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

        clearButton.title = "Очистить"
        clearButton.target = self
        clearButton.action = #selector(clearText)
        clearButton.bezelStyle = .rounded

        copyButton.title = "Копировать"
        copyButton.target = self
        copyButton.action = #selector(copyText)
        copyButton.bezelStyle = .rounded

        let bottom = NSStackView(views: [countLabel, spacer, summaryButton, clearButton, copyButton])
        bottom.orientation = .horizontal
        bottom.alignment = .centerY
        bottom.spacing = 8
        bottom.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(bottom)

        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            headerStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            headerStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            dropView.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 12),
            dropView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            dropView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            dropView.heightAnchor.constraint(equalToConstant: 76),

            statusRow.topAnchor.constraint(equalTo: dropView.bottomAnchor, constant: 12),
            statusRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            statusRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            scroll.topAnchor.constraint(equalTo: statusRow.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),

            bottom.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            bottom.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            bottom.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
        ])

        promptView.string = SettingsStore.load().promptSummary
        updateModeUI()
        updatePromptState()
        updateCount()
    }

    private func updateModeUI() {
        let summaryMode = mode == .summary
        promptContainer.isHidden = !summaryMode
        summaryButton.isHidden = !summaryMode
        promptToggle.title = promptExpanded ? "Промпт саммари ▾" : "Промпт саммари ▸"
        updateSummaryButton()
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
                self.setStatus(error.localizedDescription, color: .systemRed)
                Log.write("import: ошибка \(error.localizedDescription)")
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
    }

    @objc private func savePrompt() {
        guard !isBusy, promptView.string.count <= promptLimit else { return }
        var settings = SettingsStore.load()
        settings.promptSummary = promptView.string
        SettingsStore.save(settings)
        setStatus("Промпт саммари сохранён в настройках", color: .secondaryLabelColor)
        Log.write("summary: prompt saved chars=\(promptView.string.count)")
        updateSummaryButton()
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
                    self.summaryText = summary
                    self.summarySource = self.transcriptText
                    self.summaryPromptUsed = prompt
                    self.displaySummary()
                    self.setStatus("Саммари готово · \(elapsed)", color: .secondaryLabelColor)
                    Log.write("summary: готово chars=\(summary.count)")
                case .failure(let error):
                    self.displayTranscription()
                    self.setStatus("Не удалось сделать саммари: \(error.localizedDescription)",
                                   color: .systemRed)
                    Log.write("summary: ошибка \(error.localizedDescription)")
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
        displayedKind = .transcript
        textView.string = ""
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

    private func setBusy(_ busy: Bool) {
        chooseButton.isEnabled = !busy
        dropView.acceptsDrop = !busy
        modePopup.isEnabled = !busy
        promptToggle.isEnabled = !busy
        promptView.isEditable = !busy
        textView.isEditable = !busy
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
    }

    private func displayTranscription() {
        displayedKind = .transcript
        textView.string = transcriptText
        updateCount()
    }

    private func displaySummary() {
        displayedKind = .summary
        textView.string = summaryText
        updateCount()
    }

    private func updateCount() {
        let text = textView.string
        let count = text.count
        let prefix = displayedKind == .summary && mode == .summary ? "Саммари · " : ""
        countLabel.stringValue = count == 0 ? "" : "\(prefix)\(count) символов"
        copyButton.isEnabled = count > 0
        clearButton.isEnabled = count > 0 && !isBusy
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
