import AppKit

/// Обрезает по границам перенесённых строк. Маркер скрытого начала участвует
/// в измерении, но не попадает в текст привязки следующей гипотезы.
enum HUDTranscriptLayout {
    static let font = NSFont.systemFont(ofSize: 13)
    static let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: font))

    struct Snippet {
        let sourceText: String
        let lines: Int
        let leadingTextHidden: Bool

        var text: String {
            leadingTextHidden ? "..." + (sourceText.isEmpty ? "" : " " + sourceText) : sourceText
        }
    }

    static func fit(_ text: String, width: CGFloat, keeping previous: Snippet? = nil,
                    lineCount: Int = RecognitionPreview.defaultLineCount) -> Snippet {
        let maximumLines = RecognitionPreview.clamp(lineCount)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var source = String(trimmed.suffix(2048))
        guard !source.isEmpty else { return Snippet(sourceText: "", lines: 0, leadingTextHidden: false) }
        var hidden = trimmed.count > source.count
        if let previous, !previous.sourceText.isEmpty,
           let anchor = source.range(of: previous.sourceText, options: .backwards) {
            // Сохраняем начало уже видимой строки при сдвиге ASR-буфера.
            hidden = hidden || anchor.lowerBound != source.startIndex || previous.leadingTextHidden
            source = String(source[anchor.lowerBound...])
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let measuredWidth = max(20, width - 4)
        let container = NSTextContainer(size: NSSize(width: measuredWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        func ranges(for value: String) -> [NSRange] {
            storage.setAttributedString(NSAttributedString(string: value, attributes: attributes))
            manager.ensureLayout(for: container)
            var ranges: [NSRange] = []
            manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, _, _, glyphs, _ in
                ranges.append(manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil))
            }
            return ranges
        }
        let originalRanges = ranges(for: source)
        let start = originalRanges.count > maximumLines ? originalRanges[originalRanges.count - maximumLines].location : 0
        hidden = hidden || start > 0
        var tail = (source as NSString).substring(from: start).trimmingCharacters(in: .whitespacesAndNewlines)
        var snippet = Snippet(sourceText: tail, lines: 0, leadingTextHidden: hidden)
        var renderedLines = ranges(for: snippet.text).count
        // Многоточие может вытеснить слово на дополнительную строку. Убираем
        // слова только с начала, сохраняя конец диктовки и выбранный лимит строк.
        while renderedLines > maximumLines, !tail.isEmpty {
            if let boundary = tail.firstIndex(where: { $0.isWhitespace }),
               (String(tail[..<boundary]) as NSString).size(withAttributes: [.font: font]).width <= measuredWidth {
                tail = String(tail[boundary...]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                // Длинный URL/слово без пробелов: не удаляем весь последний токен.
                tail = String(tail.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            snippet = Snippet(sourceText: tail, lines: 0, leadingTextHidden: true)
            renderedLines = ranges(for: snippet.text).count
        }
        return Snippet(sourceText: tail, lines: renderedLines, leadingTextHidden: snippet.leadingTextHidden)
    }
}
