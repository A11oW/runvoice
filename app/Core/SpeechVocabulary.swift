import Foundation

/// Только подсказки распознавателю: словарь не заменяет похожие слова наугад.
enum SpeechVocabulary {
    static let maximumTerms = 64
    static let maximumTermLength = 80

    enum ValidationError: LocalizedError {
        case termTooLong
        case tooManyTerms

        var errorDescription: String? {
            switch self {
            case .termTooLong: return "Термин не должен превышать 80 символов. Исправьте текст и повторите добавление или сохранение."
            case .tooManyTerms: return "В словаре может быть не больше 64 терминов. Удалите лишние строки и повторите действие."
            }
        }
    }

    static func splitList(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",\r\n"))
    }

    /// Строгая проверка редактора: список добавляется целиком, без обрезки данных.
    static func validate(_ terms: [String]) -> Result<[String], ValidationError> {
        let trimmed = terms.flatMap { $0.components(separatedBy: .newlines) }.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        }
        guard trimmed.allSatisfy({ $0.count <= maximumTermLength }) else { return .failure(.termTooLong) }
        var seen = Set<String>()
        let unique = trimmed.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        guard unique.count <= maximumTerms else { return .failure(.tooManyTerms) }
        return .success(unique)
    }

    static func normalize(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        return terms.flatMap { $0.components(separatedBy: .newlines) }
            .compactMap { value in
                let term = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    .precomposedStringWithCanonicalMapping
                guard !term.isEmpty, term.count <= maximumTermLength,
                      seen.insert(term.lowercased()).inserted else { return nil }
                return term
            }.prefix(maximumTerms).map { $0 }
    }

    static func prompt(_ terms: [String]) -> String {
        // Whisper использует короткий контекст prompt; ограничиваем UTF-8,
        // сохраняя целые термины, включая кириллицу.
        var result = ""
        for term in normalize(terms) {
            let next = result.isEmpty ? term : result + ", " + term
            guard next.utf8.count <= 800 else { break }
            result = next
        }
        return result
    }
}
