import AppKit

/// Четыре последовательных клика определяет AppKit: клики в другом месте
/// или с длинным интервалом автоматически начинают новую последовательность.
final class SampleAccessLabel: NSTextField {
    var onOpen: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 4 { onOpen?() }
    }
}

final class AudioSamplePanel: NSWindowController, NSWindowDelegate {
    var isBusy: Bool { recorder.state != .idle }
    private let recorder: AudioSampleRecorder
    private let microphone: () -> (String, String)
    private let recordButton = NSButton(title: "Запись сэмпла", target: nil, action: nil)
    private let folderButton = NSButton(title: "Папка сэмплов", target: nil, action: nil)
    private let chooseButton = NSButton(title: "Выбрать папку сэмпла…", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let timerLabel = NSTextField(labelWithString: "00:00 / 01:00")
    private let indicator = NSTextField(labelWithString: "●")
    private let waveform = WaveformView(frame: .zero)
    private var selectedDirectory: URL?
    private var closing = false
    private static let folderKey = "RunvoiceAudioSampleDirectory"

    init(recorder: AudioSampleRecorder = AudioSampleRecorder(), initialDirectory: URL? = nil, microphone: @escaping () -> (String, String)) {
        self.recorder = recorder
        self.microphone = microphone
        if let initialDirectory {
            selectedDirectory = initialDirectory
        } else if let stored = UserDefaults.standard.string(forKey: Self.folderKey) {
            selectedDirectory = URL(fileURLWithPath: stored, isDirectory: true)
        } else {
            selectedDirectory = AudioSampleRecorder.sourceProject?.appendingPathComponent("local-audio-samples", isDirectory: true)
        }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 340),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Аудиосэмплы"
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self
        build()
        recorder.onChange = { [weak self] in self?.refresh() }
        recorder.onSpectrum = { [weak self] levels in self?.waveform.setSpectrum(levels) }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(on parent: NSWindow) {
        guard parent.attachedSheet == nil, let window else { return }
        closing = false
        refresh()
        parent.beginSheet(window)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { dismiss(); return false }

    @objc func dismiss() {
        closing = true
        if recorder.state == .recording || recorder.state == .preparing { recorder.stop() }
        if recorder.state == .idle { finishClose() }
    }

    private func finishClose() {
        guard let window else { return }
        window.sheetParent?.endSheet(window)
        window.orderOut(nil)
        waveform.reset()
        closing = false
    }

    private func build() {
        let content = window!.contentView!
        let title = NSTextField(labelWithString: "Запись голоса для настройки индикации")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let hint = NSTextField(wrappingLabelWithString: "Без распознавания и обработки. WAV и JSON с уровнями сохраняются локально. Автостоп через 60 секунд.")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        indicator.font = .systemFont(ofSize: 17)
        timerLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        timerLabel.identifier = NSUserInterfaceItemIdentifier("sample-timer")
        let meter = NSBox()
        meter.boxType = .custom
        meter.borderWidth = 0
        meter.fillColor = NSColor(white: 0.07, alpha: 1)
        meter.cornerRadius = 10
        meter.contentViewMargins = NSSize(width: 12, height: 6)
        meter.contentView = waveform
        meter.widthAnchor.constraint(equalToConstant: 180).isActive = true
        meter.heightAnchor.constraint(equalToConstant: 38).isActive = true
        waveform.setAccessibilityLabel("Уровень записываемого звука")
        let meterRow = NSStackView(views: [indicator, timerLabel, meter])
        meterRow.orientation = .horizontal
        meterRow.alignment = .centerY
        meterRow.spacing = 12
        recordButton.target = self; recordButton.action = #selector(toggleRecording)
        recordButton.identifier = NSUserInterfaceItemIdentifier("record-audio-sample")
        folderButton.target = self; folderButton.action = #selector(openFolder)
        chooseButton.target = self; chooseButton.action = #selector(chooseFolder)
        let buttons = NSStackView(views: [recordButton, folderButton, chooseButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        pathLabel.font = .systemFont(ofSize: 11)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        let close = NSButton(title: "Закрыть", target: self, action: #selector(dismiss))
        close.keyEquivalent = "\u{1b}"
        let stack = NSStackView(views: [title, hint, meterRow, buttons, pathLabel, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        for view in [stack, close] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        for view in [hint, pathLabel, status] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: close.topAnchor, constant: -12),
            close.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            close.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])
    }

    /// Демонстрационное состояние штатного рендера; микрофон не запускается.
    func prepareSnapshot(recording: Bool) {
        refresh()
        guard recording else { return }
        recordButton.title = "Остановить и сохранить"
        indicator.textColor = .systemRed
        timerLabel.stringValue = "00:12 / 01:00"
        status.stringValue = "Идёт запись: 12 с / 60 с"
        chooseButton.isEnabled = false
        waveform.setSnapshotLevel(0.40)
    }

    private func refresh() {
        let active = recorder.state == .recording
        let idle = recorder.state == .idle
        recordButton.title = active ? "Остановить и сохранить" : "Запись сэмпла"
        recordButton.isEnabled = idle || active
        chooseButton.isEnabled = idle
        indicator.textColor = active ? .systemRed : .tertiaryLabelColor
        indicator.setAccessibilityLabel(active ? "Идёт запись" : "Запись остановлена")
        let seconds = recorder.elapsedSeconds
        timerLabel.stringValue = String(format: "%02d:%02d / 01:00", seconds / 60, seconds % 60)
        status.stringValue = recorder.message
        pathLabel.stringValue = selectedDirectory?.path ?? "Папка не выбрана"
        pathLabel.toolTip = selectedDirectory?.path
        if !active { waveform.reset() }
        if closing && idle { finishClose() }
    }

    @objc private func toggleRecording() {
        if recorder.state == .recording { recorder.stop(); return }
        guard recorder.state == .idle else { return }
        if selectedDirectory == nil { selectFolder(startRecording: true); return }
        guard let selectedDirectory else { return }
        let (name, uid) = microphone()
        recorder.start(directory: selectedDirectory, microphone: name, deviceUID: uid)
    }

    @objc private func chooseFolder() { selectFolder(startRecording: false) }

    private func selectFolder(startRecording: Bool) {
        guard recorder.state == .idle, let window else { return }
        let picker = NSOpenPanel()
        picker.title = "Папка для аудиосэмплов"
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.canCreateDirectories = true
        picker.allowsMultipleSelection = false
        picker.directoryURL = selectedDirectory
        picker.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let folder = picker.url else { return }
            do {
                self.selectedDirectory = try AudioSampleRecorder.prepareSampleDirectory(at: folder)
                UserDefaults.standard.set(self.selectedDirectory!.path, forKey: Self.folderKey)
                self.refresh()
                if startRecording { self.toggleRecording() }
            } catch { self.status.stringValue = error.localizedDescription }
        }
    }

    @objc private func openFolder() {
        guard let selectedDirectory else { chooseFolder(); return }
        do { NSWorkspace.shared.open(try AudioSampleRecorder.prepareSampleDirectory(at: selectedDirectory)) }
        catch { status.stringValue = error.localizedDescription }
    }
}
