import Foundation

// MARK: - Проверка зависимостей

enum OpenCodeLocator {
    static func find() -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let base = home.appendingPathComponent(".npm/_npx")
        if let dirs = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) {
            for dir in dirs {
                let path = dir.appendingPathComponent("node_modules/.bin/opencode").path
                if fm.isExecutableFile(atPath: path) { return path }
            }
        }
        let brew = "/opt/homebrew/bin/opencode"
        if fm.isExecutableFile(atPath: brew) { return brew }
        return nil
    }
}

enum Dependency: CaseIterable {
    case ffmpeg, whisperServer, whisperCli, whisperModel, vadModel, opencode

    var title: String {
        switch self {
        case .ffmpeg: return "ffmpeg"
        case .whisperServer: return "whisper-server"
        case .whisperCli: return "whisper-cli"
        case .whisperModel: return "Модель Whisper"
        case .vadModel: return "VAD-модель"
        case .opencode: return "OpenCode CLI"
        }
    }

    var expected: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .ffmpeg: return "/opt/homebrew/bin/ffmpeg"
        case .whisperServer: return "/opt/homebrew/bin/whisper-server"
        case .whisperCli: return "/opt/homebrew/bin/whisper-cli"
        case .whisperModel:
            return home.appendingPathComponent(".local/share/whisper/ggml-large-v3-turbo-q5_0.bin").path
        case .vadModel:
            return home.appendingPathComponent(".local/share/whisper/ggml-silero-v5.1.2.bin").path
        case .opencode: return "npx-кэш или /opt/homebrew/bin/opencode"
        }
    }

    func isOK() -> Bool {
        let fm = FileManager.default
        switch self {
        case .ffmpeg, .whisperServer, .whisperCli:
            return fm.isExecutableFile(atPath: expected)
        case .whisperModel, .vadModel:
            return fm.fileExists(atPath: expected)
        case .opencode:
            return OpenCodeLocator.find() != nil
        }
    }
}
