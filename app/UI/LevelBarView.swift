import AppKit

/// Полоска уровня громкости микрофона.
final class LevelBarView: NSView {
    var level: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2

        NSColor(white: 1, alpha: 0.16).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

        let width = bounds.width * min(max(level, 0), 1)
        guard width > 1 else { return }

        let color: NSColor
        if level > 0.85 {
            color = .systemRed
        } else if level > 0.6 {
            color = .systemYellow
        } else {
            color = .systemGreen
        }

        color.setFill()
        let bar = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius).fill()
    }
}
