import Foundation

struct RecognitionPreview: Equatable {
    static let defaultLineCount = 3
    static let lineRange = 1...10
    static let maximumStoredWords = 160
    let enabled: Bool
    let lineCount: Int

    init(enabled: Bool = true, lineCount: Int = defaultLineCount) {
        self.enabled = enabled
        self.lineCount = Self.clamp(lineCount)
    }

    static func clamp(_ count: Int) -> Int { min(lineRange.upperBound, max(lineRange.lowerBound, count)) }
}
