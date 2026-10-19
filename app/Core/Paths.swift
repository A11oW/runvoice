import Foundation

// MARK: - Пути

enum Paths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Runvoice", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let state: URL = {
        let dir = support.appendingPathComponent("state", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var status: URL { state.appendingPathComponent("status") }
    static var log: URL { state.appendingPathComponent("dictate.log") }

    static var script: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("dictate.sh")
    }
}
