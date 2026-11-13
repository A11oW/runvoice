import Foundation

/// Очистка только HUD-черновика. Итоговое распознавание и история сюда не попадают.
enum LivePreviewText {
    static func clean(_ raw: String) -> String? {
        // HUD нужны последние несколько строк, а не многоминутный transcript.
        var text = String(raw.suffix(2048))
        if raw.count > 2048, let boundary = text.firstIndex(where: { $0.isWhitespace }) {
            text = String(text[boundary...])
        }
        for (pattern, replacement) in replacements {
            text = pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                     withTemplate: replacement)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let letters = text.filter { $0.isLetter || $0.isNumber }.count
        guard letters > 0 else { return nil }
        let punctuation = text.filter { $0.isPunctuation }.count
        guard punctuation < max(24, letters * 2) else { return nil }

        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let keys = words.map(key)
        var result: [String] = []
        var index = 0
        var dropped = 0
        while index < words.count {
            var advance = 1
            for length in stride(from: min(12, (words.count - index) / 2), through: 1, by: -1) {
                guard !keys[index..<(index + length)].contains("") else { continue }
                var repeats = 1
                while index + (repeats + 1) * length <= words.count,
                      keys[index..<(index + length)].elementsEqual(
                        keys[(index + repeats * length)..<(index + (repeats + 1) * length)]) {
                    repeats += 1
                }
                // «да да» допустимо; длинный повтор предложения — артефакт preview.
                if repeats >= (length == 1 ? 3 : 2), length == 1 || length >= 3 {
                    result.append(contentsOf: words[index..<(index + length)])
                    advance = length * repeats
                    dropped += advance - length
                    break
                }
            }
            if advance == 1 { result.append(words[index]) }
            index += advance
        }
        // Зациклившийся декодер не должен заменять последнюю хорошую гипотезу.
        guard dropped <= 8 || dropped * 2 < words.count else { return nil }
        return result.joined(separator: " ")
    }

    static func key(_ word: String) -> String {
        String(word.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static let replacements: [(NSRegularExpression, String)] = [
        (#"(?i)\[(?:blank_audio|silence|music|no_speech)\]|<\|[^>]+\|>"#, ""),
        (#"[\s\u200B\uFEFF]+"#, " "),
        (#"([,!?;:])(?:\s*\1)+"#, "$1"),
        (#"\.(?:\s*\.){2,}"#, "…"),
        (#"…(?:\s*…)+"#, "…"),
        (#"(?:[.,!?;:…]\s*){4,}"#, "."),
        (#"\s+([.,!?;:…])"#, "$1"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }
}

/// Два перекрывающихся окна подтверждают слова. Подтверждённый хвост не
/// переписывается каждой новой гипотезой; это не сборка итоговой диктовки.
struct LivePreviewStabilizer {
    private var previous: [String] = []
    private var stable: [String] = []
    private var displayed = ""
    private var earlyWord = false

    mutating func update(_ raw: String, windowStart: UInt64, firstWordOnly: Bool = true,
                         settled: Bool = false) -> String? {
        guard let text = LivePreviewText.clean(raw) else { return nil }
        let words = Array(text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            .filter { !LivePreviewText.key($0).isEmpty }.suffix(80))
        if previous.isEmpty {
            previous = words
            // Ранний первый отклик сохраняется, остальное требует согласования.
            stable = firstWordOnly ? Array(words.prefix(1)) : words
            earlyWord = firstWordOnly
            return changed()
        }
        if earlyWord {
            // Первый короткий ответ может быть частью слова (например U вместо
            // Use). Не превращаем его в вечную привязку: полное начало должно
            // совпасть в соседних ответах прежде, чем заменить этот фрагмент.
            var count = 0
            while count < previous.count, count < words.count,
                  LivePreviewText.key(previous[count]) == LivePreviewText.key(words[count]) { count += 1 }
            if settled { count = words.count }
            let old = stable.first
            previous = words
            guard count > 0 else { return nil }
            stable = Array(words.prefix(count))
            if let old, LivePreviewText.key(old) == LivePreviewText.key(stable[0]) { stable[0] = old }
            // Одно слово ещё может быть тем же незавершённым фрагментом.
            // После подтверждения следующего слова начало становится обычным
            // стабильным текстом и больше не пересматривается этим путём.
            earlyWord = stable.count == 1
            return changed()
        }
        // Подтверждаем продолжение от конца уже опубликованного текста.
        // Более длинное совпадение в старой части окна не должно задерживать
        // новые слова, совпавшие в двух последовательных гипотезах.
        if let continuation = Self.continuation(after: stable, previous: settled ? words : previous,
                                                current: words, windowStart: windowStart) {
            previous = words
            stable.append(contentsOf: continuation)
            stable = Array(stable.suffix(RecognitionPreview.maximumStoredWords))
            return changed()
        }
        let agreed = settled ? words : Self.commonRun(previous, words)
        previous = words
        guard !agreed.isEmpty else { return nil }
        let stableKeys = stable.map(LivePreviewText.key)
        let agreedKeys = agreed.map(LivePreviewText.key)
        var appended = false
        for length in stride(from: min(stable.count, agreed.count), through: 1, by: -1) {
            guard length >= 2 || stable.count == 1 || windowStart == 0 else { continue }
            for start in 0...(agreed.count - length) {
                if stableKeys.suffix(length).elementsEqual(agreedKeys[start..<(start + length)]) {
                    stable.append(contentsOf: agreed.dropFirst(start + length))
                    appended = true
                    break
                }
            }
            if appended { break }
        }
        if !appended, windowStart > 0, agreed.count >= 2 {
            var covered = 0
            for start in stableKeys.indices {
                var length = 0
                while start + length < stableKeys.count, length < agreedKeys.count,
                      stableKeys[start + length] == agreedKeys[length] { length += 1 }
                if length >= 2 { covered = max(covered, length) }
            }
            // После паузы/разрыва окна продолжаем хвост, не очищая всю карточку.
            stable.append(contentsOf: agreed.dropFirst(covered))
        }
        stable = Array(stable.suffix(RecognitionPreview.maximumStoredWords))
        return changed()
    }

    private mutating func changed() -> String? {
        let text = stable.joined(separator: " ")
        guard !text.isEmpty, text != displayed else { return nil }
        displayed = text
        return text
    }

    /// nil — надёжной привязки нет, нужен прежний путь восстановления окна.
    /// Пустой массив — привязка есть, но новых подтверждённых слов пока нет.
    private static func continuation(after stable: [String], previous: [String], current: [String],
                                     windowStart: UInt64) -> [String]? {
        let stableKeys = stable.map(LivePreviewText.key)
        let a = previous.map(LivePreviewText.key), b = current.map(LivePreviewText.key)
        let maximum = min(stableKeys.count, min(a.count, b.count))
        let minimum = stable.count == 1 || windowStart == 0 ? 1 : 2
        guard maximum >= minimum else { return nil }
        func anchorEnd(_ anchor: ArraySlice<String>, in keys: [String]) -> Int? {
            for start in stride(from: keys.count - anchor.count, through: 0, by: -1) {
                if keys[start..<(start + anchor.count)].elementsEqual(anchor) { return start + anchor.count }
            }
            return nil
        }
        for length in stride(from: maximum, through: minimum, by: -1) {
            let anchor = stableKeys.suffix(length)
            guard let oldEnd = anchorEnd(anchor, in: a), let newEnd = anchorEnd(anchor, in: b) else { continue }
            var count = 0
            while oldEnd + count < a.count, newEnd + count < b.count,
                  a[oldEnd + count] == b[newEnd + count] { count += 1 }
            return Array(current[newEnd..<(newEnd + count)])
        }
        return nil
    }

    private static func commonRun(_ previous: [String], _ current: [String]) -> [String] {
        let a = previous.map(LivePreviewText.key), b = current.map(LivePreviewText.key)
        var row = [Int](repeating: 0, count: b.count + 1)
        var best = 0, end = 0
        for i in a.indices {
            var next = [Int](repeating: 0, count: b.count + 1)
            for j in b.indices where !a[i].isEmpty && a[i] == b[j] {
                next[j + 1] = row[j] + 1
                if next[j + 1] >= best { best = next[j + 1]; end = j + 1 }
            }
            row = next
        }
        return Array(current[(end - best)..<end])
    }
}
