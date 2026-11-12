import AppKit
import QuartzCore

/// Карточка в позиции, зафиксированной при запуске операции.
final class HUDController {
    private var panel: NSPanel!
    private var stopPanel: StopPanel!
    private var stopButton: StopButton!
    private var bubble: BubbleView!
    private var iconView: NSImageView!
    private var label: NSTextField!
    private var transcriptLabel: NSTextField!
    private var timerLabel: NSTextField!
    private var levelBar: LevelBarView!
    private var clockTimer: Timer?
    private var startedAt: Date?
    private var enabled = true
    private var spaceObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var currentContent: HUDContent?
    private var sessionPosition: HUDSessionPosition?
    private var stopY: CGFloat = 16
    private var measuredTranscript = ""
    private var measuredWidth: CGFloat = 0
    private var transcriptHeight: CGFloat = 0

    private var bodyHeight: CGFloat = 64
    private let cardWidth: CGFloat = 400
    private let maximumHeight: CGFloat = 176
    private let stopWidth: CGFloat = 32
    private let stopHeight: CGFloat = 32

    var onStop: (() -> Void)?

    init() {
        setup()
    }

    /// Вызывается до запуска записи: fallback использует мышь в момент хоткея,
    /// а не её положение после подготовки микрофона или ответа Whisper.
    func beginSession(mouseLocation: NSPoint) {
        let anchor = HUDAnchor.caretRect()
            ?? NSRect(origin: mouseLocation, size: NSSize(width: 1, height: 18))
        let visible = screen(for: anchor)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(cardWidth, visible.width - 16)
        sessionPosition = HUDSessionPosition(anchor: anchor, visibleFrame: visible,
                                             reservedSize: NSSize(width: width, height: maximumHeight))
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        if !value {
            dismiss()
        }
    }

    func present(_ content: HUDContent) {
        guard enabled else {
            panel?.orderOut(nil)
            return
        }

        label.stringValue = content.text
        iconView.image = symbol(content.hudIcon)
        iconView.contentTintColor = accentColor(content.accent)
        if content.busy { startPulse() } else { stopPulse() }

        levelBar.isHidden = !content.showLevel
        if !content.showLevel { levelBar.level = 0 }

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

    func setLevel(_ level: CGFloat) {
        levelBar.level = level
    }

    func dismiss() {
        stopClock()
        stopPulse()
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
        label.stringValue = content.text
        iconView.image = symbol(content.hudIcon)
        iconView.contentTintColor = accentColor(content.accent)
        stopPulse()

        timerLabel.isHidden = (timer == nil)
        timerLabel.stringValue = timer ?? ""
        levelBar.isHidden = !content.showLevel
        levelBar.level = content.showLevel ? level : 0

        currentContent = content
        layout(content)
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
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
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
        let rect = NSRect(x: image.size.width - stopWidth - 14,
                          y: stopY,
                          width: stopWidth, height: stopHeight)
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
        let side: CGFloat = 9
        let square = NSRect(x: rect.midX - side / 2,
                            y: rect.midY - side / 2,
                            width: side, height: side)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: square, xRadius: 2, yRadius: 2).fill()
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
        let showTranscript = !content.transcript.isEmpty
        let width = min(cardWidth, (sessionPosition?.visibleFrame.width ?? 1440) - 16)
        let extra: CGFloat = content.showStop ? stopWidth + 16 : 0
        let textWidth = max(40, width - 68)
        let font = NSFont.systemFont(ofSize: 13)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
        func textHeight(_ text: String) -> CGFloat {
            ceil((text as NSString).boundingRect(
                with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes).height)
        }
        if measuredTranscript != content.transcript || measuredWidth != textWidth {
            measuredTranscript = content.transcript
            measuredWidth = textWidth
            // Бабл показывает последние строки, не разрастается на весь экран.
            var transcript = String(content.transcript.suffix(600)).trimmingCharacters(in: .whitespacesAndNewlines)
            var shortened = content.transcript.count > transcript.count
            let heightLimit: CGFloat = 102
            while !transcript.isEmpty, textHeight((shortened ? "…" : "") + transcript) > heightLimit {
                transcript.removeFirst()
                shortened = true
            }
            transcriptLabel.stringValue = (shortened ? "…" : "") + transcript
            transcriptHeight = showTranscript ? max(18, textHeight(transcriptLabel.stringValue)) : 0
        }
        transcriptLabel.isHidden = !showTranscript
        bodyHeight = showTranscript ? 44 + transcriptHeight + (content.showLevel ? 30 : 16) : 64
        let height = bodyHeight
        if panel.frame.size != NSSize(width: width, height: height) {
            panel.setContentSize(NSSize(width: width, height: height))
            bubble.frame = NSRect(x: 0, y: 0, width: width, height: height)
        }
        let bodyY: CGFloat = 0
        let labelY = bodyY + (showTranscript ? bodyHeight - 36 : (content.showLevel ? 28 : 22))
        label.frame = NSRect(x: 50, y: labelY,
                             width: max(40, width - 66 - extra), height: 20)
        iconView.frame = NSRect(x: 18, y: labelY, width: 20, height: 20)
        transcriptLabel.frame = NSRect(x: 50, y: bodyY + (content.showLevel ? 30 : 16),
                                       width: textWidth, height: transcriptHeight)
        timerLabel.frame = NSRect(x: 50, y: bodyY + 8, width: 44, height: 12)
        levelBar.frame = NSRect(x: 100, y: bodyY + 12,
                                width: max(20, width - 116 - extra), height: 4)
        stopY = labelY - 6
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

        iconView = NSImageView(frame: NSRect(x: 18, y: 22, width: 20, height: 20))
        iconView.imageScaling = .scaleProportionallyDown
        iconView.wantsLayer = true

        label = NSTextField(labelWithString: "")
        label.frame = NSRect(x: 50, y: 22, width: width - 66, height: 20)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail

        transcriptLabel = NSTextField(wrappingLabelWithString: "")
        transcriptLabel.font = .systemFont(ofSize: 13)
        transcriptLabel.textColor = NSColor(white: 1, alpha: 0.88)
        transcriptLabel.isHidden = true

        timerLabel = NSTextField(labelWithString: "")
        timerLabel.frame = NSRect(x: 50, y: 8, width: 44, height: 12)
        timerLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        timerLabel.textColor = NSColor(white: 1, alpha: 0.6)
        timerLabel.isHidden = true

        levelBar = LevelBarView(frame: NSRect(x: 100, y: 12, width: width - 116, height: 4))
        levelBar.isHidden = true

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
        bubble.addSubview(label)
        bubble.addSubview(transcriptLabel)
        bubble.addSubview(timerLabel)
        bubble.addSubview(levelBar)
        panel.contentView = bubble
    }

    private func followActiveSpace() {
        guard enabled, panel.isVisible else { return }
        place()
        panel.orderFrontRegardless()
        if stopPanel?.isVisible == true {
            placeStopPanel()
            stopPanel.orderFrontRegardless()
        }
    }

    private func showStopPanel() {
        guard enabled else { return }
        placeStopPanel()
        stopButton.isEnabled = true
        stopPanel.orderFrontRegardless()
    }

    private func hideStopPanel() {
        stopPanel?.orderOut(nil)
    }

    private func placeStopPanel() {
        let frame = panel.frame
        let x = frame.maxX - stopWidth - 14
        let y = frame.minY + stopY
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
                anchor: NSRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY, width: 1, height: 18),
                visibleFrame: screen.visibleFrame,
                reservedSize: NSSize(width: min(cardWidth, screen.visibleFrame.width - 16), height: maximumHeight))
            if let content = currentContent { layout(content) }
        }
        if let frame = sessionPosition?.frame(for: panel.frame.size) { panel.setFrameOrigin(frame.origin) }
        bubble.needsDisplay = true
    }

    // MARK: - Иконка

    private func symbol(_ name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    private func accentColor(_ accent: HUDContent.Accent) -> NSColor {
        switch accent {
        case .neutral: return NSColor(white: 1, alpha: 0.9)
        case .success: return .systemGreen
        case .info: return .systemBlue
        case .warning: return .systemOrange
        }
    }

    private func startPulse() {
        guard iconView.layer?.animation(forKey: "pulse") == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.35
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        iconView.layer?.add(pulse, forKey: "pulse")
    }

    private func stopPulse() {
        iconView.layer?.removeAnimation(forKey: "pulse")
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
        let color = hovering
            ? (NSColor.systemRed.blended(withFraction: 0.12, of: .white) ?? .systemRed)
            : .systemRed
        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2)).fill()

        let side: CGFloat = 9
        let square = NSRect(x: bounds.midX - side / 2,
                            y: bounds.midY - side / 2,
                            width: side, height: side)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: square, xRadius: 2, yRadius: 2).fill()
    }
}
