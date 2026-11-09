import Foundation

// MARK: - Лог приложения

enum Log {
    static let url = Paths.support.appendingPathComponent("app.log")

    static func write(_ text: String) {
        let line = "\(Date().timeIntervalSince1970) \(text)\n"
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil,
                          attributes: [.posixPermissions: 0o600])
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
        try? fm.setAttributes([.posixPermissions: 0o600],
                              ofItemAtPath: url.path)
    }
}
