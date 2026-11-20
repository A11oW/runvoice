import Foundation

/// Саммари распознанного текста через выбранный AI-провайдер.
/// Короткий текст обрабатывается одним запросом, длинный — по частям.
enum SummaryService {
    enum SummaryError: LocalizedError {
        case emptyTranscript
        case emptySummary
        case cancelled

        var errorDescription: String? {
            switch self {
            case .emptyTranscript: return "Нет текста для саммари."
            case .emptySummary: return "Модель вернула пустое саммари."
            case .cancelled: return "Саммари отменено."
            }
        }
    }

    /// До этого размера делаем один запрос с пользовательским промптом.
    static let singleRequestLimit = 20_000
    /// Размер промежуточной части для длинного текста.
    static let chunkLimit = 12_000
    /// Сколько раз разрешаем объединять промежуточные саммари.
    static let maxReducePasses = 3

    static func summarize(text: String,
                          prompt: String,
                          provider: AIProvider,
                          isCancelled: @escaping () -> Bool,
                          onStatus: @escaping (String) -> Void,
                          completion: @escaping (Result<String, Error>) -> Void) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(.failure(SummaryError.emptyTranscript))
            return
        }

        let effectivePrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? DefaultPrompts.summary
            : prompt
        let started = Date()
        let chunks = trimmed.count <= singleRequestLimit
            ? [trimmed]
            : split(trimmed, limit: chunkLimit)

        Log.write("summary: start chars=\(trimmed.count) chunks=\(chunks.count) promptChars=\(effectivePrompt.count) provider=\(provider.displayTitle)")

        var finished = false
        func finish(_ result: Result<String, Error>) {
            guard !finished else { return }
            finished = true
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            switch result {
            case .success(let value):
                Log.write("summary: done chars=\(value.count) elapsed=\(elapsed)ms")
            case .failure(let error):
                let message = error.localizedDescription.replacingOccurrences(of: "\n", with: " ")
                Log.write("summary: error elapsed=\(elapsed)ms \(message.prefix(200))")
            }
            DispatchQueue.main.async { completion(result) }
        }

        func generate(_ system: String, _ input: String,
                      _ next: @escaping (Result<String, Error>) -> Void) {
            if isCancelled() {
                next(.failure(SummaryError.cancelled))
                return
            }
            AIClient.generate(provider: provider, system: system, text: input) { result in
                if isCancelled() {
                    next(.failure(SummaryError.cancelled))
                    return
                }
                switch result {
                case .success(let value):
                    let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if cleaned.isEmpty {
                        next(.failure(SummaryError.emptySummary))
                    } else {
                        next(.success(value))
                    }
                case .failure(let error):
                    next(.failure(error))
                }
            }
        }

        func finalSummary(_ combined: String, pass: Int) {
            if isCancelled() {
                finish(.failure(SummaryError.cancelled))
                return
            }
            if combined.count <= singleRequestLimit || pass >= maxReducePasses {
                generate(effectivePrompt, combined) { finish($0) }
                return
            }

            let parts = split(combined, limit: chunkLimit)
            onStatus("Саммари: объединение \(pass + 1)…")
            mergeNext(parts, index: 0, partials: [], pass: pass) { merged, nextPass in
                finalSummary(merged, pass: nextPass)
            }
        }

        func mergeNext(_ parts: [String], index: Int, partials: [String], pass: Int,
                       next: @escaping (String, Int) -> Void) {
            if isCancelled() {
                finish(.failure(SummaryError.cancelled))
                return
            }
            guard index < parts.count else {
                next(partials.joined(separator: "\n\n"), pass + 1)
                return
            }
            generate(DefaultPrompts.summaryMerge, parts[index]) { result in
                switch result {
                case .success(let value):
                    mergeNext(parts, index: index + 1, partials: partials + [value],
                              pass: pass, next: next)
                case .failure(let error):
                    finish(.failure(error))
                }
            }
        }

        func chunksNext(_ index: Int, partials: [String]) {
            if isCancelled() {
                finish(.failure(SummaryError.cancelled))
                return
            }
            guard index < chunks.count else {
                let combined = partials.joined(separator: "\n\n")
                finalSummary(combined, pass: 0)
                return
            }
            onStatus("Саммари: часть \(index + 1)/\(chunks.count)…")
            let chunk = chunks[index]
            generate(DefaultPrompts.summaryChunk, chunk) { result in
                switch result {
                case .success(let value):
                    chunksNext(index + 1, partials: partials + [value])
                case .failure(let error):
                    finish(.failure(error))
                }
            }
        }

        if chunks.count <= 1 {
            generate(effectivePrompt, chunks[0]) { finish($0) }
        } else {
            chunksNext(0, partials: [])
        }
    }

    /// Режет текст по предложениям, не превышая лимит. Слишком длинное
    /// предложение делится по символам.
    static func split(_ text: String, limit: Int) -> [String] {
        guard limit > 0 else { return [text] }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var units: [String] = []
        normalized.enumerateSubstrings(in: normalized.startIndex..<normalized.endIndex,
                                       options: [.bySentences]) { substring, _, _, _ in
            if let substring,
               !substring.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                units.append(substring)
            }
        }
        if units.isEmpty {
            units = normalized.components(separatedBy: "\n")
        }

        var chunks: [String] = []
        var current = ""

        func flush() {
            let value = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { chunks.append(value) }
            current = ""
        }

        for unit in units {
            if unit.count > limit {
                flush()
                var start = unit.startIndex
                while start < unit.endIndex {
                    let end = unit.index(start, offsetBy: limit, limitedBy: unit.endIndex)
                        ?? unit.endIndex
                    let part = String(unit[start..<end])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !part.isEmpty { chunks.append(part) }
                    start = end
                }
                continue
            }

            if current.isEmpty {
                current = unit
            } else if current.count + unit.count + 1 <= limit {
                if let last = current.last, !last.isWhitespace,
                   let first = unit.first, !first.isWhitespace {
                    current += " "
                }
                current += unit
            } else {
                flush()
                current = unit
            }
        }
        flush()

        return chunks.isEmpty ? [normalized] : chunks
    }
}
