import AppKit
import UniformTypeIdentifiers

// MARK: - Окно расшифровки аудиофайла

final class AudioTranscribeWindow: NSWindowController, NSWindowDelegate {
    private let runner: DictationRunner

    private let chooseButton = NSButton()
    private let cancelButton = NSButton()
    private let copyButton = NSButton()
    private let clearButton = NSButton()
    private let fileLabel = NSTextField(labelWithString: "Файл не выбран")
    private let statusLabel = NSTextField(labelWithString: "Выберите аудиофайл или перетащите его в окно.")
    private let countLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private var textView = NSTextView()
    private let dropView = AudioDropView()

    private var process: Process?
    private var currentDirectory: URL?
    private var runToken = UUID()
    private var isRunning = false
    private var startedAt: Date?
    private var elapsedTimer: Timer?
    private var textObserver: NSObjectProtocol?

    init(runner: DictationRunner) {
        self.runner = runner
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 580),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Runvoice — Расшифровка аудио"
        window.minSize = NSSize(width: 640, height: 520)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        build()
        textObserver = NotificationCenter.default.addObserver(
            forName: NSText.didChangeNotification, object: textView, queue: .main
        ) { [weak self] _ in
            self?.updateCount()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let textObserver {
            NotificationCenter.default.removeObserver(textObserver)
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
        fileLabel.stringValue = fileName
        fileLabel.toolTip = fileName
        textView.string = text
        statusLabel.stringValue = "Готово"
        statusLabel.textColor = .secondaryLabelColor
        updateCount()
    }

    func windowWillClose(_ notification: Notification) {
        cancelTranscription()
        removeCurrentDirectory()
    }

    // MARK: - Интерфейс

    private func build() {
        guard let content = window?.contentView else { return }

        chooseButton.title = "Выбрать аудиофайл…"
        chooseButton.target = self
        chooseButton.action = #selector(chooseFile)
        chooseButton.bezelStyle = .rounded
        chooseButton.setAccessibilityLabel("Выбрать аудиофайл")

        cancelButton.title = "Отменить"
        cancelButton.target = self
        cancelButton.action = #selector(cancelTranscription)
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
        top.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(top)

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

        clearButton.title = "Очистить"
        clearButton.target = self
        clearButton.action = #selector(clearText)
        clearButton.bezelStyle = .rounded

        copyButton.title = "Копировать"
        copyButton.target = self
        copyButton.action = #selector(copyText)
        copyButton.bezelStyle = .rounded

        let bottom = NSStackView(views: [countLabel, spacer, clearButton, copyButton])
        bottom.orientation = .horizontal
        bottom.alignment = .centerY
        bottom.spacing = 8
        bottom.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(bottom)

        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            top.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            dropView.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 12),
            dropView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            dropView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            dropView.heightAnchor.constraint(equalToConstant: 76),

            statusRow.topAnchor.constraint(equalTo: dropView.bottomAnchor, constant: 12),
            statusRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            statusRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            scroll.topAnchor.constraint(equalTo: statusRow.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),

            bottom.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            bottom.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            bottom.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
        ])

        updateCount()
    }

    // MARK: - Выбор файла

    @objc private func chooseFile() {
        guard !isRunning, let window else { return }
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
        guard !isRunning else { return }
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
        textView.string = ""
        isRunning = true
        setRunning(true)
        setStatus("Распознаю аудио…", color: .secondaryLabelColor)
        updateCount()

        let process = runner.transcribe(file: url, outputDirectory: directory) { [weak self] result in
            guard let self, self.runToken == token else { return }
            let elapsed = self.elapsedText()
            self.process = nil
            self.isRunning = false
            self.setRunning(false)
            self.stopElapsed()
            switch result {
            case .success(let text):
                self.textView.string = text
                self.setStatus("Готово · \(elapsed)", color: .secondaryLabelColor)
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

    // MARK: - Отмена и результат

    @objc private func cancelTranscription() {
        guard isRunning else { return }
        runToken = UUID()
        process?.terminate()
        process = nil
        isRunning = false
        setRunning(false)
        stopElapsed()
        setStatus("Отменено", color: .secondaryLabelColor)
        updateCount()
        Log.write("import: отменено пользователем")
        removeCurrentDirectory()
    }

    @objc private func clearText() {
        guard !isRunning else { return }
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

    private func setRunning(_ running: Bool) {
        chooseButton.isEnabled = !running
        dropView.acceptsDrop = !running
        cancelButton.isHidden = !running
        if running {
            spinner.startAnimation(nil)
            startedAt = Date()
            startElapsedTimer()
        } else {
            spinner.stopAnimation(nil)
        }
    }

    private func setStatus(_ text: String, color: NSColor) {
        statusLabel.stringValue = text
        statusLabel.textColor = color
    }

    private func updateCount() {
        let count = textView.string.count
        countLabel.stringValue = count == 0 ? "" : "\(count) символов"
        copyButton.isEnabled = count > 0
        clearButton.isEnabled = count > 0 && !isRunning
    }

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateElapsed()
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
        updateElapsed()
    }

    private func stopElapsed() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        startedAt = nil
    }

    private func updateElapsed() {
        guard isRunning else { return }
        setStatus("Распознаю аудио… \(elapsedText())", color: .secondaryLabelColor)
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
