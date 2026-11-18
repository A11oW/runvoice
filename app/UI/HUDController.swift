import AppKit
import QuartzCore

/// Карточка в позиции, зафиксированной при запуске операции.
final class HUDController {
    private var panel: NSPanel!
    private var stopPanel: HUDActionPanel!
    private var pausePanel: HUDActionPanel!
    private var pauseButton: HUDActionButton!
    private var stopButton: HUDActionButton!
    private var bubble: BubbleView!
    private var iconView: HUDStatusIconView!
    private var spinner: HUDSpinnerView!
    private var spinnerRunning = false
    private var applicationIconView: NSImageView!
    private var displayedApplication: HUDApplication?
    private var label: NSTextField!
    private var transcriptLabel: NSTextField!
    private var timerLabel: NSTextField!
    private var waveform: WaveformView!
    private var pauseLabel: NSTextField!
    private var clockTimer: Timer?
    private var recordingClock = HUDRecordingClock()
    private var spaceObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var currentContent: HUDContent?
    private var sessionPosition: HUDSessionPosition?
    private var pauseOrigin = NSPoint.zero
    private var stopOrigin = NSPoint.zero
    private var measuredTranscript = ""
    private var measuredWidth: CGFloat = 0
    private var transcriptHeight: CGFloat = 0
    private var reservedTranscriptLines = 0
    private var previewOptions = RecognitionPreview()
    private var measuredLineCount = 0
    private var transcriptSnippet: HUDTranscriptLayout.Snippet?

    private var bodyHeight = HUDLayout.rowHeight
    private let cardWidth = HUDLayout.recordingWidth
    private var maximumHeight: CGFloat {
        previewOptions.enabled ? HUDLayout.maximumHeight(lines: previewOptions.lineCount) : HUDLayout.rowHeight
    }
    private let stopWidth = HUDLayout.actionSize
    private let stopHeight = HUDLayout.actionSize

    var onStop: (() -> Void)?
    var onTogglePause: (() -> Void)?

    init() {
        setup()
    }

    /// Использует мышь в момент хоткея, до подготовки микрофона и ответа ASR.
    func beginSession(mouseLocation: NSPoint) {
        stopClock()
        reservedTranscriptLines = 0
        measuredWidth = -1
        transcriptLabel.stringValue = ""
        transcriptSnippet = nil
        waveform.reset()
        let anchor = NSRect(origin: mouseLocation, size: .zero)
        let visible = screen(for: anchor)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(cardWidth, visible.width - 16)
        sessionPosition = HUDSessionPosition(anchor: anchor, visibleFrame: visible,
                                             reservedSize: NSSize(width: width, height: min(maximumHeight, visible.height - 16)))
    }

    func setPreviewOptions(_ options: RecognitionPreview) {
        guard options != previewOptions else { return }
        let enabledChanged = options.enabled != previewOptions.enabled
        previewOptions = options
        reservedTranscriptLines = 0
        measuredWidth = -1
        transcriptLabel.stringValue = ""
        transcriptSnippet = nil
        if var content = currentContent {
            if enabledChanged { content.transcript = "" }
            present(content)
        }
    }

    func present(_ content: HUDContent) {
        if sessionPosition == nil { beginSession(mouseLocation: NSEvent.mouseLocation) }
        configure(content)

        if content.showLevel {
            if content.isPaused { pauseClock() }
            else { startClock() }
        } else {
            stopClock()
        }

        currentContent = content
        layout(content)
        place()

        let wasVisible = panel.isVisible
        // orderFrontRegardless нужен при каждом показе: панель могла остаться
        // на другом Space/дисплее, хотя сама считает себя видимой.
        panel.orderFrontRegardless()
        if content.showStop {
            showControls()
        } else {
            hideControls()
        }
        if !wasVisible {
            Log.write("showHUD frame=\(panel.frame)")
        }
    }

    func setSpectrum(_ levels: [CGFloat]) {
        guard currentContent?.showLevel == true, currentContent?.isPaused != true else { return }
        waveform.setSpectrum(levels)
        pauseButton.audioLevel = waveform.activityLevel
    }

    func dismiss() {
        stopClock()
        setSpinnerRunning(false)
        hideControls()
        currentContent = nil
        panel?.orderOut(nil)
    }

    /// Отладочный режим: отрисовать бабл в PNG.
    func snapshot(to path: String,
                  content: HUDContent,
                  timer: String? = "00:07",
                  level: CGFloat = 0.65,
                  hovering: Bool = false,
                  pulsePhase: CGFloat = 0.35,
                  morph: CGFloat? = nil,
                  completion: @escaping () -> Void) {
        if sessionPosition == nil { beginSession(mouseLocation: NSEvent.mouseLocation) }
        configure(content)

        timerLabel.isHidden = (timer == nil)
        timerLabel.stringValue = timer ?? ""
        currentContent = content
        layout(content)
        waveform.setSnapshotLevel(content.showLevel && !content.isPaused ? level : 0)
        pauseButton.audioLevel = waveform.activityLevel
        var centers: [String: CGFloat] = [:]
        if content.showLevel {
            centers["timer"] = timerLabel.frame.midY
            if content.isPaused {
                centers["pauseLabel"] = pauseLabel.frame.midY
            } else { centers["spectrum"] = waveform.frame.midY }
            if content.showStop {
                centers["pauseButton"] = pauseOrigin.y + stopHeight / 2
                centers["stop"] = stopOrigin.y + stopHeight / 2
            }
        } else {
            centers[content.showSpinner ? "spinner" : "icon"] = content.showSpinner ? spinner.frame.midY : iconView.frame.midY
            centers["title"] = label.frame.midY
            if content.delivery?.application != nil { centers["application"] = applicationIconView.frame.midY }
        }
        let metadata: [String: Any] = [
            "text": content.displayText, "width": panel.frame.width, "height": panel.frame.height,
            "titleWidth": label.frame.width, "titleFittingWidth": label.fittingSize.width,
            "titleFont": label.font?.pointSize ?? 0,
            "preview": transcriptLabel.stringValue, "lineLimit": transcriptLabel.maximumNumberOfLines,
            "rowCenters": centers, "spectrumWidth": waveform.frame.width, "spectrumHeight": waveform.frame.height,
            "spinnerRunning": spinner.isAnimating,
            "paused": content.isPaused, "timer": timerLabel.stringValue,
            "recordingSeconds": recordingClock.elapsed(at: ProcessInfo.processInfo.systemUptime),
            "pauseIndicatorVisible": !pauseLabel.isHidden,
            "controlsVisible": content.showStop,
            "pauseAction": content.isPaused ? "resume" : "pause",
            "pauseDiameter": HUDLayout.recordingButtonDiameter,
            "recordDiameter": HUDLayout.recordingGlyphSize,
            "pauseGlyph": content.isPaused || hovering ? "pause" : "record",
            "recordingPulseVisible": content.showStop && content.showLevel && !content.isPaused,
            "pauseX": pauseOrigin.x, "stopX": stopOrigin.x, "timerX": timerLabel.frame.minX,
            "spectrumVisible": !waveform.isHidden
        ]
        if let json = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]) {
            try? json.write(to: URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("json"))
        }
        place()
        panel.orderFrontRegardless()
        if content.showStop {
            showControls()
        } else {
            hideControls()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if let image = self.renderImage(of: self.panel.contentView, opaque: true) {
                if content.showStop {
                    self.drawControls(on: image, hovering: hovering, pulsePhase: pulsePhase, morph: morph)
                }
                if let tiff = image.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiff),
                   let png = bitmap.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                }
            }
            self.hideControls()
            completion()
        }
    }

    private func renderImage(of view: NSView?, opaque: Bool) -> NSImage? {
        guard let view,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                        pixelsWide: Int(view.bounds.width * 2), pixelsHigh: Int(view.bounds.height * 2),
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        // Независимо от дисплея, на котором осталась мышь: снимки всегда 2×,
        // без растягивания растрового кэша с внешнего экрана 1×.
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        if opaque {
            NSColor.windowBackgroundColor.setFill()
            view.bounds.fill()
        }
        if let cg = rep.cgImage, let ctx = NSGraphicsContext.current?.cgContext {
            ctx.draw(cg, in: view.bounds)
        }
        image.unlockFocus()
        return image
    }

    private func drawControls(on image: NSImage, hovering: Bool, pulsePhase: CGFloat, morph: CGFloat?) {
        image.lockFocus()
        defer { image.unlockFocus() }
        HUDActionButton.drawBadge(in: NSRect(origin: stopOrigin, size: NSSize(width: stopWidth, height: stopHeight)),
                                  style: .stop, hovering: false)
        HUDActionButton.drawBadge(in: NSRect(origin: pauseOrigin, size: NSSize(width: stopWidth, height: stopHeight)),
                                  style: pauseButton.style, hovering: hovering, pulsePhase: pulsePhase,
                                  audioLevel: waveform.activityLevel, morph: morph)
    }

    private func configure(_ content: HUDContent) {
        let title = NSMutableAttributedString(string: content.displayText,
                                              attributes: [.font: HUDLayout.titleFont, .foregroundColor: NSColor.white])
        if let delivery = content.delivery {
            let suffix = " · \(delivery.words)"
            title.addAttribute(.foregroundColor, value: NSColor(white: 1, alpha: 0.64),
                               range: NSRange(location: title.length - suffix.utf16.count, length: suffix.utf16.count))
        }
        label.attributedStringValue = title
        label.toolTip = content.displayText
        label.isHidden = content.showLevel
        iconView.isHidden = content.showLevel || content.showSpinner
        spinner.isHidden = !content.showSpinner
        setSpinnerRunning(content.showSpinner)
        iconView.setSymbol(content.hudIcon)
        iconView.tint = accentColor(content.accent)
        let application = content.delivery?.application
        applicationIconView.isHidden = application == nil
        if displayedApplication != application {
            displayedApplication = application
            applicationIconView.image = application?.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
                ?? (application == nil ? nil : NSImage(systemSymbolName: "app", accessibilityDescription: nil))
        }
        if content.isPaused || currentContent?.isPaused == true {
            waveform.reset()
            pauseButton.audioLevel = 0
        }
        waveform.isHidden = !content.showLevel || content.isPaused
        pauseLabel.isHidden = !content.showLevel || !content.isPaused
        pauseButton.style = content.isPaused ? .paused : .recording
        let pauseAction = content.isPaused ? "Продолжить запись" : "Приостановить запись"
        pauseButton.toolTip = pauseAction
        pauseButton.setAccessibilityLabel(pauseAction)
        panel.setAccessibilityLabel(content.isPaused ? "Диктовка на паузе" : content.showLevel ? "Запись звука" : content.displayText)
    }

    private func setSpinnerRunning(_ running: Bool) {
        guard running != spinnerRunning else { return }
        spinnerRunning = running
        if running { spinner.startAnimation(nil) }
        else { spinner.stopAnimation(nil) }
    }

    // MARK: - Часы записи

    private func startClock() {
        recordingClock.resume(at: ProcessInfo.processInfo.systemUptime)
        timerLabel.isHidden = false
        updateClock()
        guard clockTimer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateClock()
        }
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    private func pauseClock() {
        recordingClock.pause(at: ProcessInfo.processInfo.systemUptime)
        clockTimer?.invalidate()
        clockTimer = nil
        timerLabel.isHidden = false
        updateClock()
    }

    private func stopClock() {
        clockTimer?.invalidate()
        clockTimer = nil
        recordingClock.reset()
        timerLabel.stringValue = ""
        timerLabel.isHidden = true
    }

    private func updateClock() {
        let seconds = Int(recordingClock.elapsed(at: ProcessInfo.processInfo.systemUptime))
        timerLabel.stringValue = String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - Компоновка

    private func layout(_ content: HUDContent) {
        if sessionPosition == nil { beginSession(mouseLocation: NSEvent.mouseLocation) }
        let showTranscript = previewOptions.enabled && content.showLevel && !content.transcript.isEmpty
        let maximumWidth = min(cardWidth, (sessionPosition?.visibleFrame.width ?? 1440) - 16)
        let showsApplication = content.delivery?.application != nil
        let width = content.showLevel ? maximumWidth
            : HUDLayout.compactWidth(titleWidth: label.fittingSize.width, showsApplication: showsApplication, maximum: maximumWidth)
        let textWidth = max(40, width - HUDLayout.padding * 2)
        let availableHeight = sessionPosition?.availableHeight ?? 900
        let linesOnScreen = max(1, Int((availableHeight - HUDLayout.rowHeight - 10) / HUDTranscriptLayout.lineHeight))
        let lineCount = min(previewOptions.lineCount, linesOnScreen)
        transcriptLabel.maximumNumberOfLines = lineCount
        if measuredTranscript != content.transcript || measuredWidth != textWidth || measuredLineCount != lineCount {
            measuredTranscript = content.transcript
            measuredWidth = textWidth
            measuredLineCount = lineCount
            let snippet = HUDTranscriptLayout.fit(showTranscript ? content.transcript : "", width: textWidth,
                                                   keeping: transcriptSnippet, lineCount: lineCount)
            transcriptSnippet = snippet
            transcriptLabel.stringValue = snippet.text
            // При записи карточка только растёт до выбранного числа строк и больше
            // не сжимается вслед за короткой/пересмотренной гипотезой.
            if showTranscript { reservedTranscriptLines = min(lineCount, max(reservedTranscriptLines, snippet.lines)) }
            transcriptHeight = showTranscript ? CGFloat(reservedTranscriptLines) * HUDTranscriptLayout.lineHeight + 4 : 0
        }
        transcriptLabel.isHidden = !showTranscript
        bodyHeight = showTranscript ? HUDLayout.rowHeight + transcriptHeight + 6 : HUDLayout.rowHeight
        let height = bodyHeight
        if panel.frame.size != NSSize(width: width, height: height) {
            panel.setContentSize(NSSize(width: width, height: height))
            bubble.frame = NSRect(x: 0, y: 0, width: width, height: height)
        }
        let centerY = height - HUDLayout.rowHeight / 2
        iconView.frame = NSRect(x: HUDLayout.padding, y: centerY - 10, width: 20, height: 20)
        spinner.frame = NSRect(x: HUDLayout.padding + 2, y: centerY - 8, width: 16, height: 16)
        applicationIconView.frame = NSRect(x: 42, y: centerY - 8, width: 16, height: 16)
        let titleX: CGFloat = showsApplication ? 64 : 42
        let titleHeight = ceil(label.fittingSize.height)
        label.frame = NSRect(x: titleX, y: centerY - titleHeight / 2,
                             width: max(0, width - titleX - HUDLayout.padding), height: titleHeight)
        transcriptLabel.frame = NSRect(x: HUDLayout.padding, y: 10, width: textWidth, height: transcriptHeight)
        let timerHeight = ceil(timerLabel.fittingSize.height)
        timerLabel.frame = NSRect(x: HUDLayout.timerX, y: centerY - timerHeight / 2, width: 56, height: timerHeight)
        if content.showLevel {
            let spectrumWidth = min(HUDLayout.spectrumSize.width, max(12, width - 122))
            waveform.frame = NSRect(x: width - HUDLayout.padding - spectrumWidth,
                                    y: centerY - HUDLayout.spectrumSize.height / 2,
                                    width: spectrumWidth, height: HUDLayout.spectrumSize.height)
            let pauseTitleHeight = ceil(pauseLabel.fittingSize.height)
            pauseLabel.frame = NSRect(x: waveform.frame.minX, y: centerY - pauseTitleHeight / 2,
                                      width: waveform.frame.width, height: pauseTitleHeight)
        }
        pauseOrigin = NSPoint(x: HUDLayout.padding, y: centerY - stopHeight / 2)
        stopOrigin = NSPoint(x: HUDLayout.padding + stopWidth + HUDLayout.actionGap, y: pauseOrigin.y)
    }

    private func setup() {
        let width: CGFloat = 330
        let height = bodyHeight

        bubble = BubbleView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        stopButton = HUDActionButton(frame: NSRect(x: 0, y: 0, width: stopWidth, height: stopHeight))
        stopButton.style = .stop
        stopButton.target = self
        stopButton.action = #selector(stopPressed)
        stopButton.title = ""
        stopButton.isBordered = false
        stopButton.toolTip = "Остановить запись и отменить диктовку"
        stopButton.setAccessibilityLabel("Остановить запись и отменить диктовку")
        stopPanel = makeActionPanel(button: stopButton)

        pauseButton = HUDActionButton(frame: stopButton.frame)
        pauseButton.target = self
        pauseButton.action = #selector(pausePressed)
        pauseButton.title = ""
        pauseButton.isBordered = false
        pausePanel = makeActionPanel(button: pauseButton)

        iconView = HUDStatusIconView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        spinner = HUDSpinnerView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        spinner.isHidden = true
        applicationIconView = NSImageView(frame: .zero)
        applicationIconView.imageScaling = .scaleProportionallyDown
        applicationIconView.contentTintColor = .white

        label = NSTextField(labelWithString: "")
        label.frame = NSRect(x: 50, y: 22, width: width - 66, height: 20)
        label.font = HUDLayout.titleFont
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail

        transcriptLabel = NSTextField(wrappingLabelWithString: "")
        transcriptLabel.font = .systemFont(ofSize: 13)
        transcriptLabel.maximumNumberOfLines = previewOptions.lineCount
        transcriptLabel.lineBreakMode = .byWordWrapping
        transcriptLabel.textColor = NSColor(white: 1, alpha: 0.88)
        transcriptLabel.isHidden = true

        timerLabel = NSTextField(labelWithString: "")
        timerLabel.frame = NSRect(x: 50, y: 8, width: 44, height: 12)
        timerLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        timerLabel.textColor = NSColor(white: 1, alpha: 0.82)
        timerLabel.isHidden = true

        waveform = WaveformView(frame: .zero)
        waveform.isHidden = true

        pauseLabel = NSTextField(labelWithString: "Пауза")
        pauseLabel.isHidden = true
        pauseLabel.font = HUDLayout.titleFont
        pauseLabel.textColor = NSColor(white: 1, alpha: 0.64)
        pauseLabel.alignment = .right

        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.followActiveSpace()
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.followActiveSpace()
        }

        bubble.addSubview(iconView)
        bubble.addSubview(spinner)
        bubble.addSubview(applicationIconView)
        bubble.addSubview(label)
        bubble.addSubview(transcriptLabel)
        bubble.addSubview(timerLabel)
        bubble.addSubview(waveform)
        bubble.addSubview(pauseLabel)
        panel.contentView = bubble
    }

    private func makeActionPanel(button: NSButton) -> HUDActionPanel {
        let actionPanel = HUDActionPanel(contentRect: button.bounds,
                                         styleMask: [.borderless, .nonactivatingPanel],
                                         backing: .buffered, defer: false)
        actionPanel.isFloatingPanel = true
        actionPanel.becomesKeyOnlyIfNeeded = true
        actionPanel.level = .statusBar
        actionPanel.backgroundColor = .clear
        actionPanel.isOpaque = false
        actionPanel.hasShadow = false
        actionPanel.hidesOnDeactivate = false
        actionPanel.isMovable = false
        actionPanel.animationBehavior = .none
        actionPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        actionPanel.contentView = button
        return actionPanel
    }

    private func followActiveSpace() {
        guard panel.isVisible else { return }
        place()
        panel.orderFrontRegardless()
        if stopPanel?.isVisible == true {
            placeControls()
            stopPanel.orderFrontRegardless()
            pausePanel.orderFrontRegardless()
        }
    }

    private func showControls() {
        placeControls()
        stopButton.isEnabled = true
        pauseButton.isEnabled = true
        stopPanel.orderFrontRegardless()
        pausePanel.orderFrontRegardless()
        pauseButton.pulseEnabled = true
    }

    private func hideControls() {
        waveform?.reset()
        pauseButton?.pulseEnabled = false
        stopPanel?.orderOut(nil)
        pausePanel?.orderOut(nil)
    }

    private func placeControls() {
        let frame = panel.frame
        let x = frame.minX + stopOrigin.x
        let y = frame.minY + stopOrigin.y
        stopPanel.setFrame(NSRect(x: x, y: y, width: stopWidth, height: stopHeight),
                           display: false)
        pausePanel.setFrame(NSRect(x: frame.minX + pauseOrigin.x, y: frame.minY + pauseOrigin.y,
                                   width: stopWidth, height: stopHeight), display: false)
    }

    @objc private func pausePressed() {
        guard currentContent?.showStop == true, currentContent?.showLevel == true else { return }
        onTogglePause?()
    }

    @objc private func stopPressed() {
        guard currentContent?.showStop == true, stopButton.isEnabled else { return }
        stopButton.isEnabled = false
        hideControls()
        onStop?()
    }

    private func screen(for anchor: NSRect) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) }
            ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func place() {
        if sessionPosition == nil { beginSession(mouseLocation: NSEvent.mouseLocation) }
        // Только отключение исходного дисплея допускает перенос на оставшийся экран.
        if let position = sessionPosition,
           !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(position.visibleFrame) }),
           let screen = NSScreen.screens.first {
            sessionPosition = HUDSessionPosition(
                anchor: NSRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY, width: 0, height: 0),
                visibleFrame: screen.visibleFrame,
                reservedSize: NSSize(width: min(cardWidth, screen.visibleFrame.width - 16), height: maximumHeight))
            if let content = currentContent { layout(content) }
        }
        if let frame = sessionPosition?.frame(for: panel.frame.size) { panel.setFrameOrigin(frame.origin) }
        bubble.needsDisplay = true
    }

    // MARK: - Иконка

    private func accentColor(_ accent: HUDContent.Accent) -> NSColor {
        switch accent {
        case .neutral: return NSColor(white: 1, alpha: 0.9)
        case .success: return .systemGreen
        case .info: return .systemBlue
        case .warning: return .systemOrange
        }
    }

    deinit {
        clockTimer?.invalidate()
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }
}


private final class HUDActionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class HUDActionButton: NSButton {
    enum Style { case recording, paused, stop }
    var style: Style = .recording {
        didSet { if style != oldValue { refreshAppearance() } }
    }
    var pulseEnabled = false {
        didSet {
            if !pulseEnabled { hovering = false; needsDisplay = true }
            updatePulse()
        }
    }
    private var hovering = false
    var audioLevel: CGFloat = 0 {
        didSet {
            if pulseEnabled && style == .recording { animateAura() }
            else { stopAura() }
        }
    }
    private var aura = RecordingAuraEnvelope()
    private var auraTimer: Timer?
    private var auraFrame: TimeInterval = 0
    private var morph: CGFloat = 0
    private var morphTimer: Timer?
    private static let red = NSColor(srgbRed: 0.91, green: 0.26, blue: 0.24, alpha: 1)

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self,
                                       userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        refreshAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        refreshAppearance()
    }

    private func refreshAppearance() {
        if style != .recording { stopAura() }
        let target: CGFloat = style == .paused || hovering ? 1 : 0
        morphTimer?.invalidate(); morphTimer = nil
        guard morph != target else { needsDisplay = true; return }
        let initial = morph
        let started = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let progress = min(1, (ProcessInfo.processInfo.systemUptime - started) / 0.18)
            let eased = progress * progress * (3 - 2 * progress)
            self.morph = initial + (target - initial) * CGFloat(eased)
            self.needsDisplay = true
            if progress >= 1 { timer.invalidate(); self.morphTimer = nil }
        }
        morphTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        needsDisplay = true
    }

    private func updatePulse() {
        // Наведение меняет только форму: аура питается тем же спектром, что и волна.
        if !pulseEnabled {
            morphTimer?.invalidate(); morphTimer = nil
            morph = style == .paused ? 1 : 0
            audioLevel = 0
        }
        needsDisplay = true
    }

    private func animateAura() {
        guard auraTimer == nil else { return }
        auraFrame = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard self.pulseEnabled, self.style == .recording else { self.stopAura(); return }
            let now = ProcessInfo.processInfo.systemUptime
            self.aura.advance(toward: self.audioLevel, elapsed: now - self.auraFrame)
            self.auraFrame = now
            self.needsDisplay = true
            if abs(self.aura.level - self.audioLevel) < 0.001 {
                timer.invalidate(); self.auraTimer = nil
            }
        }
        auraTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopAura() {
        auraTimer?.invalidate(); auraTimer = nil
        aura.reset()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        Self.drawBadge(in: bounds, style: style, hovering: hovering,
                       audioLevel: aura.level, morph: morph,
                       auraEnabled: pulseEnabled)
    }

    private static func circle(in rect: NSRect, diameter: CGFloat) -> NSRect {
        NSRect(x: rect.midX - diameter / 2, y: rect.midY - diameter / 2,
               width: diameter, height: diameter)
    }

    static func drawBadge(in rect: NSRect, style: Style, hovering: Bool,
                          pulsePhase: CGFloat? = nil, audioLevel: CGFloat = 0,
                          morph: CGFloat? = nil, auraEnabled: Bool = true) {
        if style == .stop {
            NSColor(white: 1, alpha: hovering ? 0.8 : 1).setFill()
            let square = circle(in: rect, diameter: 10)
            NSBezierPath(roundedRect: square, xRadius: 1.5, yRadius: 1.5).fill()
            return
        }
        NSColor(white: 0.23, alpha: 1).setFill()
        NSBezierPath(ovalIn: circle(in: rect, diameter: HUDLayout.recordingButtonDiameter)).fill()
        if style == .recording && auraEnabled {
            let strength = min(1, max(0, audioLevel))
            let diameter = HUDLayout.recordingGlyphSize + 1
                + (HUDLayout.recordingButtonDiameter - HUDLayout.recordingGlyphSize - 1.5) * strength
            red.withAlphaComponent(0.16 + 0.28 * strength).setFill()
            NSBezierPath(ovalIn: circle(in: rect, diameter: diameter)).fill()
        }
        let progress = min(1, max(0, morph ?? (style == .paused || hovering ? 1 : 0)))
        red.setFill()
        // Две половины одного круга плавно сужаются в штрихи; разрыва формы нет.
        for right in [false, true] {
            let width: CGFloat = 4 - 2 * progress
            let x = right ? rect.midX + progress : rect.midX - 4 + progress
            let outer: CGFloat = 4 - 3 * progress
            let inner = progress
            let left = right ? inner : outer
            let rightRadius = right ? outer : inner
            let path = CGMutablePath()
            let y = rect.midY - 4
            let k: CGFloat = 0.55228475
            path.move(to: CGPoint(x: x + left, y: y))
            path.addLine(to: CGPoint(x: x + width - rightRadius, y: y))
            path.addCurve(to: CGPoint(x: x + width, y: y + rightRadius),
                          control1: CGPoint(x: x + width - rightRadius + rightRadius * k, y: y),
                          control2: CGPoint(x: x + width, y: y + rightRadius - rightRadius * k))
            path.addLine(to: CGPoint(x: x + width, y: y + 8 - rightRadius))
            path.addCurve(to: CGPoint(x: x + width - rightRadius, y: y + 8),
                          control1: CGPoint(x: x + width, y: y + 8 - rightRadius + rightRadius * k),
                          control2: CGPoint(x: x + width - rightRadius + rightRadius * k, y: y + 8))
            path.addLine(to: CGPoint(x: x + left, y: y + 8))
            path.addCurve(to: CGPoint(x: x, y: y + 8 - left),
                          control1: CGPoint(x: x + left - left * k, y: y + 8),
                          control2: CGPoint(x: x, y: y + 8 - left + left * k))
            path.addLine(to: CGPoint(x: x, y: y + left))
            path.addCurve(to: CGPoint(x: x + left, y: y),
                          control1: CGPoint(x: x, y: y + left - left * k),
                          control2: CGPoint(x: x + left - left * k, y: y))
            path.closeSubpath()
            if let context = NSGraphicsContext.current?.cgContext {
                context.addPath(path)
                context.setFillColor(red.cgColor)
                context.fillPath()
            }
        }
    }
}
