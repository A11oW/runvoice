import AppKit

// MARK: - Бабл HUD

final class BubbleView: NSView {
    private let corner: CGFloat = 14

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: corner, yRadius: corner)
        NSColor(calibratedWhite: 0.11, alpha: 0.97).setFill()
        path.fill()
    }
}
