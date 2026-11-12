import AppKit

/// Контрастный индикатор для чёрного HUD. Таймер работает только пока виден процесс.
final class HUDSpinnerView: NSView {
    private var timer: Timer?
    private(set) var phase = 0
    var isAnimating: Bool { timer != nil }

    func startAnimation(_ sender: Any?) {
        guard timer == nil else { return }
        phase = 0
        needsDisplay = true
        let timer = Timer(timeInterval: 0.075, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.phase = (self.phase + 1) % 12
            self.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopAnimation(_ sender: Any?) {
        timer?.invalidate()
        timer = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = max(0, min(bounds.width, bounds.height) / 2 - 1)
        for index in 0..<12 {
            let age = (index - phase + 12) % 12
            NSColor(white: 1, alpha: 0.15 + 0.8 * CGFloat(12 - age) / 12).setStroke()
            let angle = CGFloat.pi / 2 - CGFloat(index) * 2 * .pi / 12
            let path = NSBezierPath()
            path.lineWidth = 1.5
            path.lineCapStyle = .round
            path.move(to: NSPoint(x: bounds.midX + cos(angle) * radius * 0.58,
                                  y: bounds.midY + sin(angle) * radius * 0.58))
            path.line(to: NSPoint(x: bounds.midX + cos(angle) * radius,
                                  y: bounds.midY + sin(angle) * radius))
            path.stroke()
        }
    }

    deinit { timer?.invalidate() }
}
