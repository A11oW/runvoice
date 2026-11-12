import AppKit

/// Обрезает по границам уже перенесённых строк, а не по одному символу.
/// NSTextField дополнительно ограничен тем же числом строк.
enum HUDTranscriptLayout {
    static let font = NSFont.systemFont(ofSize: 13)
    static let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: font))

    struct Snippet { let text: String; let lines: Int }

    static func fit(_ text: String, width: CGFloat, keeping previous: String = "",
                    lineCount: Int = RecognitionPreview.defaultLineCount) -> Snippet {
        let maximumLines = RecognitionPreview.clamp(lineCount)
        var source = String(text.suffix(2048)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return Snippet(text: "", lines: 0) }
        if !previous.isEmpty, let anchor = source.range(of: previous, options: .backwards) {
            // Начало уже видимой строки остаётся началом строки, даже когда
            // ограниченный ASR-буфер удалил старые слова перед ней.
            source = String(source[anchor.lowerBound...])
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let storage = NSTextStorage(string: source, attributes: [.font: font, .paragraphStyle: paragraph])
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: max(20, width - 4), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        var ranges: [NSRange] = []
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, _, _, glyphs, _ in
            ranges.append(manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil))
        }
        let start = ranges.count > maximumLines ? ranges[ranges.count - maximumLines].location : 0
        let tail = (source as NSString).substring(from: start).trimmingCharacters(in: .whitespacesAndNewlines)
        return Snippet(text: tail, lines: min(maximumLines, ranges.count))
    }
}
