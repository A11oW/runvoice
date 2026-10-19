import AppKit

/// Плавающий бабл статуса, привязанный к иконке в меню-баре.
final class HUDController {
    private let statusItem: NSStatusItem
    private var panel: NSPanel!
    private var bubble: BubbleView!
    private var spinner: NSProgressIndicator!
    private var label: NSTextField!
    private var levelBar: LevelBarView!
    private var enabled = true

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        setup()
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        if !value { panel?.orderOut(nil) }
    }

    func present(text: String, busy: Bool, showLevel: Bool = false) {
        guard enabled else {
            panel?.orderOut(nil)
            return
        }

        if !panel.isVisible {
            place()
            panel.orderFrontRegardless()
            Log.write("showHUD frame=\(panel.frame) visible=\(panel.isVisible) screen=\(panel.screen?.frame ?? .zero)")
        }

        label.stringValue = text
        levelBar.isHidden = !showLevel
        if !showLevel { levelBar.level = 0 }

        if busy {
            spinner.isHidden = false
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
            spinner.isHidden = true
        }
    }

    func setLevel(_ level: CGFloat) {
        levelBar.level = level
    }

    func dismiss() {
        panel?.orderOut(nil)
    }

    /// Отладочный режим: отрисовать бабл в PNG.
    func snapshot(to path: String, completion: @escaping () -> Void) {
        label.stringValue = "🎤 Слушаю…"
        levelBar.isHidden = false
        levelBar.level = 0.65
        spinner.isHidden = false
        spinner.startAnimation(nil)
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

    private func setup() {
        let w: CGFloat = 330
        let body: CGFloat = 64
        let h: CGFloat = body + 9   // тело + хвостик

        bubble = BubbleView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        bubble.bodyHeight = body

        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        spinner = NSProgressIndicator(frame: NSRect(x: 18, y: (body - 18) / 2, width: 18, height: 18))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false

        let title = NSTextField(labelWithString: "Runvoice")
        title.frame = NSRect(x: 50, y: body - 26, width: w - 66, height: 16)
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.textColor = NSColor(white: 1, alpha: 0.55)

        label = NSTextField(labelWithString: "")
        label.frame = NSRect(x: 50, y: 16, width: w - 66, height: 20)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail

        levelBar = LevelBarView(frame: NSRect(x: 50, y: 5, width: w - 66, height: 4))
        levelBar.isHidden = true

        bubble.addSubview(spinner)
        bubble.addSubview(title)
        bubble.addSubview(label)
        bubble.addSubview(levelBar)
        panel.contentView = bubble
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
}
