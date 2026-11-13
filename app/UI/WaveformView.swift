import AppKit

/// Каждая полоса показывает свою частоту в текущем кадре, без сдвига влево.
struct WaveformLevels {
    static let count = AudioSpectrumAnalyzer.bandCount
    private(set) var levels = [CGFloat](repeating: 0, count: count)

    mutating func update(_ values: [CGFloat]) {
        for index in 0..<Self.count {
            let value = index < values.count ? values[index] : 0
            levels[index] = value.isFinite ? min(1, max(0, value)) : 0
        }
    }

    mutating func reset() { levels = [CGFloat](repeating: 0, count: Self.count) }
}

final class WaveformView: NSView {
    private var current = WaveformLevels()

    func setSpectrum(_ levels: [CGFloat]) {
        current.update(levels)
        needsDisplay = true
    }

    func reset() {
        current.reset()
        needsDisplay = true
    }

    /// Только для встроенного snapshot-режима, без микрофона и таймера анимации.
    func setSnapshotLevel(_ level: CGFloat) {
        let spectrum: [CGFloat] = [0.12, 0.22, 0.42, 0.68, 0.92, 0.78, 0.52, 0.36, 0.46,
                                  0.62, 0.81, 0.58, 0.41, 0.28, 0.37, 0.24, 0.15, 0.08]
        current.update(spectrum.map { $0 * min(1, max(0, level)) / 0.65 })
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemGreen.setFill()
        let step = bounds.width / CGFloat(WaveformLevels.count)
        let barWidth = min(2, max(1, step - 1.5))
        for (index, level) in current.levels.enumerated() {
            // Более заметный отклик спокойной речи; аудио для модели не усиливается.
            let height = 1 + sqrt(level) * max(0, bounds.height - 1)
            let rect = NSRect(x: CGFloat(index) * step + (step - barWidth) / 2,
                              y: (bounds.height - height) / 2, width: barWidth, height: height)
            NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }
}
