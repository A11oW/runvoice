import AppKit

enum HUDLayout {
    static let recordingWidth: CGFloat = 360
    static let rowHeight: CGFloat = 40
    static let padding: CGFloat = 14
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
