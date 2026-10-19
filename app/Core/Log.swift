import Foundation

// MARK: - Лог приложения

enum Log {
    static let url = Paths.support.appendingPathComponent("app.log")

    static func write(_ text: String) {
        let line = "\(Date().timeIntervalSince1970) \(text)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
