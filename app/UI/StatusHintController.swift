import AppKit

/// Стрелка привязана к кнопке строки меню, независимо от ограничения ширины у края экрана.
struct StatusHintLayout {
    let frame: NSRect
    let arrowX: CGFloat
    static let bodyHeight: CGFloat = 42
    static let arrowHeight: CGFloat = 7

    init(width: CGFloat, anchor: NSRect, visibleFrame: NSRect) {
        let width = min(width, visibleFrame.width - 16)
        let x = max(visibleFrame.minX + 8, min(anchor.midX - width / 2, visibleFrame.maxX - 8 - width))
        frame = NSRect(x: x, y: anchor.minY - 4 - Self.bodyHeight - Self.arrowHeight,
                       width: width, height: Self.bodyHeight + Self.arrowHeight)
        arrowX = max(14, min(anchor.midX - x, width - 14))
    }
}

/// Хинт запуска не участвует в жизненном цикле HUD и никогда не забирает фокус.
final class StatusHintController {
    private let panel: StatusHintPanel
    private let hintView = StatusHintView()
    private var timer: Timer?
    private var generation = UUID()
    private var anchor = NSRect.zero
    private var visibleFrame = NSRect.zero

    var isVisible: Bool { panel.isVisible }
    var text: String { hintView.label.stringValue }

    init() {
        panel = StatusHintPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.identifier = NSUserInterfaceItemIdentifier("startup-hint")
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = hintView
        hintView.onClick = { [weak self] in self?.dismiss() }
    }

    func show(shortcut: String, anchor: NSRect, visibleFrame: NSRect) {
        timer?.invalidate()
        generation = UUID()
        self.anchor = anchor
        self.visibleFrame = visibleFrame
        layout(shortcut: shortcut)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        let timer = Timer(timeInterval: 4, repeats: false) { [weak self] _ in self?.dismiss() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func update(shortcut: String) {
        guard isVisible else { return }
        layout(shortcut: shortcut)
    }

    func dismiss(animated: Bool = true) {
        timer?.invalidate()
        timer = nil
        guard isVisible else { return }
        generation = UUID()
        let token = generation
        if !animated { panel.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            self.panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.generation == token else { return }
            self.panel.orderOut(nil)
        })
    }

    private func layout(shortcut: String) {
        hintView.label.stringValue = "Для диктовки нажмите \(shortcut)"
        let layout = StatusHintLayout(width: ceil(hintView.label.fittingSize.width) + 32,
                                      anchor: anchor, visibleFrame: visibleFrame)
        panel.setFrame(layout.frame, display: false)
        hintView.arrowX = layout.arrowX
        hintView.label.frame = NSRect(x: 16, y: (StatusHintLayout.bodyHeight - 18) / 2,
                                       width: layout.frame.width - 32, height: 18)
        panel.setAccessibilityLabel(text)
        hintView.needsDisplay = true
    }

    func snapshot(to path: String) {
        guard let rep = hintView.bitmapImageRepForCachingDisplay(in: hintView.bounds) else { return }
        hintView.cacheDisplay(in: hintView.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    deinit { timer?.invalidate() }
}

private final class StatusHintPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class StatusHintView: NSView {
    let label = NSTextField(labelWithString: "")
    var arrowX: CGFloat = 0
    var onClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.035, alpha: 0.98).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: bounds.width, height: StatusHintLayout.bodyHeight),
                     xRadius: 12, yRadius: 12).fill()
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: arrowX - 7, y: StatusHintLayout.bodyHeight - 1))
        arrow.line(to: NSPoint(x: arrowX, y: bounds.maxY))
        arrow.line(to: NSPoint(x: arrowX + 7, y: StatusHintLayout.bodyHeight - 1))
        arrow.close()
        arrow.fill()
    }
}
