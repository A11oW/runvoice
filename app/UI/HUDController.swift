import AppKit
import QuartzCore

/// Плавающий бабл статуса, привязанный к иконке в меню-баре.
final class HUDController {
    private let statusItem: NSStatusItem
    private var panel: NSPanel!
    private var bubble: BubbleView!
    private var iconView: NSImageView!
    private var label: NSTextField!
    private var timerLabel: NSTextField!
    private var levelBar: LevelBarView!
    private var clockTimer: Timer?
    private var startedAt: Date?
    private var enabled = true
    private var spaceObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?

    private let bodyHeight: CGFloat = 64
    private let tailHeight: CGFloat = 9
    private let minWidth: CGFloat = 220
    private let maxWidth: CGFloat = 420

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        setup()
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        if !value { panel?.orderOut(nil) }
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

        let labelY: CGFloat = content.showLevel ? 28 : 22
        let width = preferredWidth(for: content.text, showLevel: content.showLevel)
        resize(to: width, labelY: labelY)
        place()

        let wasVisible = panel.isVisible
        // orderFrontRegardless нужен при каждом показе: панель могла остаться
        // на другом Space/дисплее, хотя сама считает себя видимой.
        panel.orderFrontRegardless()
        if !wasVisible {
            Log.write("showHUD frame=\(panel.frame) width=\(width)")
        }
    }

    func setLevel(_ level: CGFloat) {
        levelBar.level = level
    }

    func dismiss() {
        stopClock()
        stopPulse()
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

        let labelY: CGFloat = content.showLevel ? 28 : 22
        let width = preferredWidth(for: content.text, showLevel: content.showLevel)
        resize(to: width, labelY: labelY)
        place()
        panel.orderFrontRegardless()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if let view = self.panel.contentView,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                let image = NSImage(size: view.bounds.size)
                image.lockFocus()
                NSColor.windowBackgroundColor.setFill()
                view.bounds.fill()
                if let cg = rep.cgImage, let ctx = NSGraphicsContext.current?.cgContext {
                    ctx.draw(cg, in: view.bounds)
                }
                image.unlockFocus()
                if let tiff = image.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiff),
                   let png = bitmap.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                }
            }
            completion()
        }
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

    private func preferredWidth(for text: String, showLevel: Bool) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        let textWidth = (text as NSString).size(withAttributes: [.font: font]).width
        let minimum = showLevel ? 260 : minWidth
        return min(max(ceil(textWidth) + 80, minimum), maxWidth)
    }

    private func resize(to width: CGFloat, labelY: CGFloat) {
        let height = bodyHeight + tailHeight
        if abs(panel.frame.width - width) > 0.5 {
            panel.setContentSize(NSSize(width: width, height: height))
            bubble.frame = NSRect(x: 0, y: 0, width: width, height: height)
        }
        label.frame = NSRect(x: 50, y: labelY, width: width - 66, height: 20)
        iconView.frame = NSRect(x: 18, y: labelY, width: 20, height: 20)
        timerLabel.frame = NSRect(x: 50, y: 8, width: 44, height: 12)
        levelBar.frame = NSRect(x: 100, y: 12, width: width - 116, height: 4)
    }

    private func setup() {
        let width: CGFloat = 330
        let height = bodyHeight + tailHeight

        bubble = BubbleView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        bubble.bodyHeight = bodyHeight

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

        iconView = NSImageView(frame: NSRect(x: 18, y: 22, width: 20, height: 20))
        iconView.imageScaling = .scaleProportionallyDown
        iconView.wantsLayer = true

        label = NSTextField(labelWithString: "")
        label.frame = NSRect(x: 50, y: 22, width: width - 66, height: 20)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail

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
        bubble.addSubview(timerLabel)
        bubble.addSubview(levelBar)
        panel.contentView = bubble
    }

    private func followActiveSpace() {
        guard enabled, panel.isVisible else { return }
        place()
        panel.orderFrontRegardless()
    }

    private func place() {
        let size = panel.frame.size

        guard let button = statusItem.button, let window = button.window else {
            let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
                ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            panel.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.maxY - size.height))
            bubble.tailX = size.width / 2
            bubble.needsDisplay = true
            return
        }

        let rectInWindow = button.convert(button.bounds, to: nil)
        let screenRect = window.convertToScreen(rectInWindow)
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var x = screenRect.midX - size.width / 2
        x = max(vf.minX + 6, min(x, vf.maxX - size.width - 6))

        // хвостик смотрит в иконку, бабл висит сразу под меню-баром
        panel.setFrameOrigin(NSPoint(x: x, y: vf.maxY - size.height + 2))
        bubble.tailX = screenRect.midX - x
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
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }
}
