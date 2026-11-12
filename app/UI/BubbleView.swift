import AppKit

// MARK: - Бабл HUD

final class BubbleView: NSView {
    private let corner: CGFloat = 18

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: corner, yRadius: corner)
        NSColor(calibratedWhite: 0.055, alpha: 0.98).setFill()
        path.fill()
    }
}
