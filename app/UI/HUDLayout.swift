import AppKit

enum HUDLayout {
    static let recordingWidth: CGFloat = 360
    static let rowHeight: CGFloat = 40
    static let padding: CGFloat = 14
    static let actionSize: CGFloat = 22 // область нажатия; геометрия строки сохраняется
    static let recordingButtonDiameter: CGFloat = 18
    static let recordingGlyphSize: CGFloat = 8
    static let actionGap: CGFloat = 8
    static let timerX = padding + actionSize * 2 + actionGap + 8
    static let iconSize: CGFloat = 20
    static let applicationIconSize: CGFloat = 16
    static let spectrumSize = NSSize(width: 72, height: 24)
    static let titleFont = NSFont.systemFont(ofSize: 12, weight: .medium)

    static func compactWidth(titleWidth: CGFloat, showsApplication: Bool, maximum: CGFloat) -> CGFloat {
        let leading = padding + iconSize + 8 + (showsApplication ? applicationIconSize + 6 : 0)
        return min(maximum, leading + ceil(titleWidth) + padding)
    }

    static func maximumHeight(lines: Int) -> CGFloat {
        rowHeight + 8 + CGFloat(RecognitionPreview.clamp(lines)) * HUDTranscriptLayout.lineHeight + 2
    }
}

/// Только огибающая красной ауры. Геометрия и чувствительность спектра не меняются.
struct RecordingAuraEnvelope {
    private(set) var level: CGFloat = 0

    static func target(for spectrum: [CGFloat]) -> CGFloat {
        let levels = spectrum.map { $0.isFinite ? min(1, max(0, $0)) : 0 }
            .sorted(by: >).prefix(6)
        guard !levels.isEmpty else { return 0 }
        let mean = levels.reduce(0, +) / CGFloat(levels.count)
        // Динамический диапазон подобран по локальным сэмплам обычной речи.
        // Порог не усиливает фон, запас до края сохраняется и на громких слогах.
        return min(0.88, max(0, (mean - 0.04) * 2))
    }

    mutating func advance(toward target: CGFloat, elapsed: TimeInterval) {
        let target = target.isFinite ? min(0.88, max(0, target)) : 0
        let tau = target > level ? 0.10 : 0.32
        let dt = elapsed.isFinite ? min(0.1, max(0, elapsed)) : 0
        level += (target - level) * CGFloat(1 - exp(-dt / tau))
        if abs(level - target) < 0.001 { level = target }
    }

    mutating func reset() { level = 0 }
}
