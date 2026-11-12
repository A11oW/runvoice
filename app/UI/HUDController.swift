import AppKit

/// Карточка в позиции, зафиксированной при запуске операции.
final class HUDController {
    private var panel: NSPanel!
    private var stopPanel: StopPanel!
    private var stopButton: StopButton!
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
    private var clockTimer: Timer?
    private var startedAt: Date?
    private var spaceObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var currentContent: HUDContent?
    private var sessionPosition: HUDSessionPosition?
    private var stopOrigin = NSPoint.zero
    private var measuredTranscript = ""
    private var measuredWidth: CGFloat = 0
    private var transcriptHeight: CGFloat = 0
    private var reservedTranscriptLines = 0
    private var previewOptions = RecognitionPreview()
    private var measuredLineCount = 0

    private var bodyHeight = HUDLayout.rowHeight
    private let cardWidth = HUDLayout.recordingWidth
    private var maximumHeight: CGFloat {
        previewOptions.enabled ? HUDLayout.maximumHeight(lines: previewOptions.lineCount) : HUDLayout.rowHeight
    }
    private let stopWidth = HUDLayout.iconSize
    private let stopHeight = HUDLayout.iconSize

    var onStop: (() -> Void)?

    init() {
        setup()
    }

    /// Использует мышь в момент хоткея, до подготовки микрофона и ответа ASR.
    func beginSession(mouseLocation: NSPoint) {
        reservedTranscriptLines = 0
        measuredWidth = -1
        transcriptLabel.stringValue = ""
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
        if var content = currentContent {
            if enabledChanged { content.transcript = "" }
            present(content)
        }
    }

    func present(_ content: HUDContent) {
        configure(content)

        if content.showLevel {
            if startedAt == nil { startClock() }
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
            showStopPanel()
        } else {
            hideStopPanel()
        }
        if !wasVisible {
            Log.write("showHUD frame=\(panel.frame)")
        }
    }

    func setSpectrum(_ levels: [CGFloat]) {
        guard currentContent?.showLevel == true else { return }
        waveform.setSpectrum(levels)
    }

    func dismiss() {
        stopClock()
        setSpinnerRunning(false)
        hideStopPanel()
        currentContent = nil
        panel?.orderOut(nil)
    }

    /// Отладочный режим: отрисовать бабл в PNG.
    func snapshot(to path: String,
                  content: HUDContent,
                  timer: String? = "00:07",
                  level: CGFloat = 0.65,
                  completion: @escaping () -> Void) {
        configure(content)

        timerLabel.isHidden = (timer == nil)
        timerLabel.stringValue = timer ?? ""
        currentContent = content
        layout(content)
        waveform.setSnapshotLevel(content.showLevel ? level : 0)
        var centers: [String: CGFloat] = [:]
        if content.showLevel {
            centers["timer"] = timerLabel.frame.midY
            centers["spectrum"] = waveform.frame.midY
            if content.showStop { centers["stop"] = stopOrigin.y + stopHeight / 2 }
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
            "spinnerRunning": spinner.isAnimating
        ]
        if let json = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]) {
            try? json.write(to: URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("json"))
        }
        place()
        panel.orderFrontRegardless()
        if content.showStop {
            showStopPanel()
        } else {
            hideStopPanel()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if let image = self.renderImage(of: self.panel.contentView, opaque: true) {
                if content.showStop {
                    self.drawStopBadge(on: image)
                }
                if let tiff = image.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiff),
                   let png = bitmap.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                }
            }
            self.hideStopPanel()
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

    private func drawStopBadge(on image: NSImage) {
        image.lockFocus()
        defer { image.unlockFocus() }
        StopButton.drawBadge(in: NSRect(origin: stopOrigin, size: NSSize(width: stopWidth, height: stopHeight)),
                             hovering: false)
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
        waveform.isHidden = !content.showLevel
        panel.setAccessibilityLabel(content.showLevel ? "Запись звука" : content.displayText)
    }

    private func setSpinnerRunning(_ running: Bool) {
        guard running != spinnerRunning else { return }
        spinnerRunning = running
        if running { spinner.startAnimation(nil) }
        else { spinner.stopAnimation(nil) }
    }

    // MARK: - Часы записи

    private func startClock() {
        startedAt = Date()
        timerLabel.stringValue = "00:00"
        timerLabel.isHidden = false
        clockTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateClock()
        }
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    private func stopClock() {
        clockTimer?.invalidate()
        clockTimer = nil
        startedAt = nil
        timerLabel.stringValue = ""
        timerLabel.isHidden = true
    }

    private func updateClock() {
        guard let startedAt else { return }
        let seconds = Int(Date().timeIntervalSince(startedAt))
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
                                                   keeping: transcriptLabel.stringValue, lineCount: lineCount)
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
        timerLabel.frame = NSRect(x: 42, y: centerY - timerHeight / 2, width: 56, height: timerHeight)
        if content.showLevel {
            let spectrumWidth = min(HUDLayout.spectrumSize.width, max(12, width - 122))
            waveform.frame = NSRect(x: width - HUDLayout.padding - spectrumWidth,
                                    y: centerY - HUDLayout.spectrumSize.height / 2,
                                    width: spectrumWidth, height: HUDLayout.spectrumSize.height)
        }
        stopOrigin = NSPoint(x: HUDLayout.padding, y: centerY - stopHeight / 2)
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

        stopPanel = StopPanel(contentRect: NSRect(x: 0, y: 0, width: stopWidth, height: stopHeight),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        stopPanel.isFloatingPanel = true
        stopPanel.becomesKeyOnlyIfNeeded = true
        stopPanel.level = .statusBar
        stopPanel.backgroundColor = .clear
        stopPanel.isOpaque = false
        stopPanel.hasShadow = false
        stopPanel.ignoresMouseEvents = false
        stopPanel.hidesOnDeactivate = false
        stopPanel.isMovable = false
        stopPanel.animationBehavior = .none
        stopPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        stopButton = StopButton(frame: NSRect(x: 0, y: 0, width: stopWidth, height: stopHeight))
        stopButton.target = self
        stopButton.action = #selector(stopPressed)
        stopButton.title = ""
        stopButton.isBordered = false
        stopButton.toolTip = "Остановить запись и отменить диктовку"
        stopButton.setAccessibilityLabel("Остановить запись")
        stopPanel.contentView = stopButton

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
        panel.contentView = bubble
    }

    private func followActiveSpace() {
        guard panel.isVisible else { return }
        place()
        panel.orderFrontRegardless()
        if stopPanel?.isVisible == true {
            placeStopPanel()
            stopPanel.orderFrontRegardless()
        }
    }

    private func showStopPanel() {
        placeStopPanel()
        stopButton.isEnabled = true
        stopPanel.orderFrontRegardless()
    }

    private func hideStopPanel() {
        stopPanel?.orderOut(nil)
    }

    private func placeStopPanel() {
        let frame = panel.frame
        let x = frame.minX + stopOrigin.x
        let y = frame.minY + stopOrigin.y
        stopPanel.setFrame(NSRect(x: x, y: y, width: stopWidth, height: stopHeight),
                           display: false)
    }

    @objc private func stopPressed() {
        guard stopButton.isEnabled else { return }
        stopButton.isEnabled = false
        hideStopPanel()
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


private final class StopPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class StopButton: NSButton {
    private var hovering = false

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
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        Self.drawBadge(in: bounds, hovering: hovering)
    }

    static func drawBadge(in rect: NSRect, hovering: Bool) {
        HUDIconDrawing.filledCircle(in: rect, color: NSColor(white: 1, alpha: hovering ? 1 : 0.85)) {
            let side: CGFloat = 6
            let square = NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: square, xRadius: 1, yRadius: 1).fill()
        }
    }
}
