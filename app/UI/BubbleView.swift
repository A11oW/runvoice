import AppKit

// MARK: - Бабл HUD

final class BubbleView: NSView {
    var bodyHeight: CGFloat = 64
    var tailX: CGFloat = 0

    private let tailWidth: CGFloat = 18
    private let tailHeight: CGFloat = 9
    private let corner: CGFloat = 14

    override func draw(_ dirtyRect: NSRect) {
        let body = NSRect(x: 0, y: 0, width: bounds.width, height: bodyHeight)
        let path = NSBezierPath(roundedRect: body, xRadius: corner, yRadius: corner)

        let minX = corner + tailWidth / 2
        let maxX = max(minX, bounds.width - corner - tailWidth / 2)
        let centerX = min(max(minX, tailX), maxX)

        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: centerX - tailWidth / 2, y: bodyHeight - 1))
        tail.line(to: NSPoint(x: centerX, y: bodyHeight + tailHeight))
        tail.line(to: NSPoint(x: centerX + tailWidth / 2, y: bodyHeight - 1))
        tail.close()

        NSColor(calibratedWhite: 0.11, alpha: 0.97).setFill()
        path.fill()
        tail.fill()
    }
}
