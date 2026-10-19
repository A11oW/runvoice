import Foundation

/// Запускает bin/dictate.sh с окружением, собранным из настроек приложения.
final class DictationRunner {
    enum Failure: Swift.Error {
        case missingScript
    }

    func run(_ action: DictationAction) throws {
        guard let script = Paths.script else { throw Failure.missingScript }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, action.rawValue]

        var environment = ProcessInfo.processInfo.environment
        environment["DICTATE_STATE_DIR"] = Paths.state.path
        environment["HUD_BIN"] = "/nonexistent"   // окно рисует само приложение
        environment["DICTATE_NOTIFY"] = "0"
        environment["DICTATE_NO_PASTE"] = "1"     // ⌘V отправляет само приложение

        let settings = SettingsStore.load()
        let forwarded: [(String, String?)] = [
            ("DICTATE_PROMPT_FIX", settings.promptFix.isEmpty ? nil : settings.promptFix),
            ("DICTATE_PROMPT_AGENT", settings.promptAgent.isEmpty ? nil : settings.promptAgent),
            ("WHISPER_LANG", settings.language.isEmpty ? nil : settings.language),
            ("OC_PROVIDER", settings.provider.isEmpty ? nil : settings.provider),
            ("OC_MODEL_ID", settings.model.isEmpty ? nil : settings.model),
            ("OC_BASE_URL", settings.baseURL.isEmpty ? nil : settings.baseURL),
            ("DICTATE_RESTORE_CLIPBOARD", settings.restoreClipboard ? "1" : nil),
        ]
        for (key, value) in forwarded {
            if let value { environment[key] = value }
        }

        let base = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = base + ":" + (environment["PATH"] ?? "")
        process.environment = environment

        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}
