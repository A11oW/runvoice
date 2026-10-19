import Foundation

/// Запускает bin/dictate.sh с окружением, собранным из настроек приложения.
final class DictationRunner {
    enum Failure: Swift.Error {
        case missingScript
        case missingModel(path: String?)
    }

    func run() throws {
        guard let script = Paths.script else { throw Failure.missingScript }

        let settings = SettingsStore.load()
        guard let model = WhisperModelStore.activeModel(settings: settings) else {
            throw Failure.missingModel(path: settings.whisperModelPath.isEmpty ? nil : settings.whisperModelPath)
        }
        try launch(script: script, action: "toggle", model: model, settings: settings)
    }

    /// Прогрев whisper-server после сохранения настроек.
    /// Не блокирует UI: скрипт запускается в фоне и сам ждёт готовности сервера.
    func warmUp() {
        guard let script = Paths.script else { return }
        let settings = SettingsStore.load()
        guard let model = WhisperModelStore.activeModel(settings: settings) else { return }
        do {
            try launch(script: script, action: "warmup", model: model, settings: settings)
            Log.write("warmup: запущен")
        } catch {
            Log.write("warmup: не удалось запустить (\(error.localizedDescription))")
        }
    }

    private func launch(script: URL, action: String, model: WhisperModelFile, settings: Settings) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, action]
        process.environment = makeEnvironment(model: model, settings: settings)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    private func makeEnvironment(model: WhisperModelFile, settings: Settings) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["DICTATE_STATE_DIR"] = Paths.state.path
        environment["HUD_BIN"] = "/nonexistent"   // окно рисует само приложение
        environment["DICTATE_NOTIFY"] = "0"
        environment["DICTATE_NO_PASTE"] = "1"     // ⌘V отправляет само приложение
        environment["WHISPER_MODEL"] = model.path

        if let server = WhisperModelStore.bundledServer {
            environment["WHISPER_SERVER_BIN"] = server.path
        }
        if let cli = WhisperModelStore.bundledCLI {
            environment["WHISPER_CLI_BIN"] = cli.path
        }
        if let vad = WhisperModelStore.bundledVAD {
            environment["WHISPER_VAD_MODEL"] = vad.path
        }

        let forwarded: [(String, String?)] = [
            ("DICTATE_PROMPT_FIX", settings.promptFix.isEmpty ? nil : settings.promptFix),
            ("WHISPER_LANG", settings.language.isEmpty ? nil : settings.language),
            ("OC_PROVIDER", settings.provider.isEmpty ? nil : settings.provider),
            ("OC_MODEL_ID", settings.model.isEmpty ? nil : settings.model),
            ("OC_BASE_URL", settings.baseURL.isEmpty ? nil : settings.baseURL),
            ("DICTATE_USE_OC", settings.useOpenCode ? "1" : "0"),
            ("DICTATE_RESTORE_CLIPBOARD", settings.restoreClipboard ? "1" : nil),
        ]
        for (key, value) in forwarded {
            if let value { environment[key] = value }
        }

        let base = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = base + ":" + (environment["PATH"] ?? "")
        return environment
    }
}
