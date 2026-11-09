import Foundation

// MARK: - Проверка зависимостей

enum OpenCodeLocator {
    static func find() -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        // Сначала стандартные установки, затем PATH, только потом npm-кэш.
        for path in ["/opt/homebrew/bin/opencode", "/usr/local/bin/opencode"] {
            if isSafeExecutable(path) { return path }
        }
        if let path = Dependency.locateExecutable("opencode"), isSafeExecutable(path) {
            return path
        }

        let base = home.appendingPathComponent(".npm/_npx")
        if let dirs = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) {
            for dir in dirs {
                let path = dir.appendingPathComponent("node_modules/.bin/opencode").path
                if isSafeExecutable(path) { return path }
            }
        }
        return nil
    }

    private static func isSafeExecutable(_ path: String) -> Bool {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: path),
              let attrs = try? fm.attributesOfItem(atPath: path),
              let mode = attrs[.posixPermissions] as? NSNumber else { return false }
        // Не запускаем файлы, доступные на запись группе или всем.
        return (mode.intValue & 0o022) == 0
    }
}

enum Dependency: CaseIterable, Equatable {
    case ffmpeg, whisperServer, whisperCli, whisperModel, vadModel, opencode

    /// Что показываем в «Диагностике». Встроенные компоненты (whisper-server,
    /// whisper-cli, VAD) не выводим — они всегда часть бандла.
    static let diagnosticsCases: [Dependency] = [.ffmpeg, .whisperModel, .opencode]

    /// Поиск исполняемого файла в PATH и типовых каталогах Homebrew.
    static func locateExecutable(_ name: String) -> String? {
        var directories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        directories.append(contentsOf: ["/opt/homebrew/bin", "/usr/local/bin"])
        for directory in directories where !directory.isEmpty {
            let path = URL(fileURLWithPath: directory).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

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
        case .ffmpeg: return Dependency.locateExecutable("ffmpeg") ?? "/opt/homebrew/bin/ffmpeg"
        case .whisperServer:
            return WhisperModelStore.bundledServer?.path ?? "/opt/homebrew/bin/whisper-server"
        case .whisperCli:
            return WhisperModelStore.bundledCLI?.path ?? "/opt/homebrew/bin/whisper-cli"
        case .whisperModel:
            return WhisperModelStore.activeModel(settings: SettingsStore.load())?.path
                ?? "не выбрана — Настройки → Модели"
        case .vadModel:
            return WhisperModelStore.bundledVAD?.path
                ?? home.appendingPathComponent(".local/share/whisper/ggml-silero-v5.1.2.bin").path
        case .opencode: return "npx-кэш или /opt/homebrew/bin/opencode"
        }
    }

    func isOK() -> Bool {
        let fm = FileManager.default
        switch self {
        case .ffmpeg:
            return Dependency.locateExecutable("ffmpeg") != nil
        case .whisperServer:
            return fm.isExecutableFile(atPath: expected)
        case .whisperCli:
            return fm.isExecutableFile(atPath: expected)
        case .whisperModel:
            return WhisperModelStore.activeModel(settings: SettingsStore.load()) != nil
        case .vadModel:
            return fm.fileExists(atPath: expected)
        case .opencode:
            return OpenCodeLocator.find() != nil
        }
    }
}
