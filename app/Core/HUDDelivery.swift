import Foundation

/// Приложение-получатель фиксируется непосредственно перед отправкой вставки.
struct HUDApplication: Equatable {
    let name: String
    let bundleURL: URL?
}

struct HUDDelivery {
    let application: HUDApplication?
    let wordCount: Int

    init(text: String, application: HUDApplication?) {
        self.application = application
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex,
                                 options: [.byWords, .substringNotRequired]) { _, _, _, _ in count += 1 }
        wordCount = count
    }

    var words: String { Self.words(wordCount) }

    static func words(_ count: Int) -> String {
        let lastTwo = count % 100
        let noun: String
        if (11...14).contains(lastTwo) { noun = "слов" }
        else {
            switch count % 10 {
            case 1: noun = "слово"
            case 2...4: noun = "слова"
            default: noun = "слов"
            }
        }
        return "\(count) \(noun)"
    }
}
