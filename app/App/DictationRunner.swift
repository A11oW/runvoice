import Foundation

/// Запускает bin/dictate.sh с окружением, собранным из настроек приложения.
final class DictationRunner {
    enum Failure: Swift.Error {
        case missingScript
        case missingModel(path: String?)
        case emptyTranscription
        case transcription(String)
    }

    func run() throws {
        guard let script = Paths.script else { throw Failure.missingScript }

        let settings = SettingsStore.load()
        guard let model = WhisperModelStore.activeModel(settings: settings) else {
            throw Failure.missingModel(path: settings.whisperModelPath.isEmpty ? nil : settings.whisperModelPath)
        }
        try launch(script: script, action: "toggle", model: model, settings: settings)
    }

    /// Немедленная отмена текущей записи без распознавания и вставки.
    func cancel() throws {
        guard let script = Paths.script else { throw Failure.missingScript }
        let settings = SettingsStore.load()
        try launch(script: script, action: "cancel", model: nil, settings: settings)
    }

    /// Расшифровка аудиофайла без HUD, вставки и истории.
    /// Результат пишется в `outputDirectory/result.txt`, сообщение об ошибке — в `result.txt.err`.
    func transcribe(file: URL, outputDirectory: URL,
                    completion: @escaping (Result<String, Error>) -> Void) -> Process? {
        guard let script = Paths.script else {
            completion(.failure(Failure.missingScript))
            return nil
        }
        let settings = SettingsStore.load()
        guard let model = WhisperModelStore.activeModel(settings: settings) else {
            completion(.failure(Failure.missingModel(
                path: settings.whisperModelPath.isEmpty ? nil : settings.whisperModelPath)))
            return nil
        }

        let result = outputDirectory.appendingPathComponent("result.txt")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, "transcribe-file", file.path, result.path]
        process.environment = makeEnvironment(model: model, settings: settings)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { proc in
            let text = (try? String(contentsOf: result, encoding: .utf8)) ?? ""
            let failureFile = URL(fileURLWithPath: result.path + ".err")
            let failure = (try? String(contentsOf: failureFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                if proc.terminationStatus == 0 {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        completion(.failure(Failure.emptyTranscription))
                    } else {
                        completion(.success(text))
                    }
                } else if proc.terminationStatus == 130 || proc.terminationStatus == 143 {
                    // Процесс остановлен пользователем — окно уже показало «Отменено».
                    return
                } else {
                    completion(.failure(Failure.transcription(
                        failure?.isEmpty == false ? failure! : "Не удалось расшифровать аудио.")))
                }
            }
        }
        do {
            try process.run()
            Log.write("import: запущена расшифровка \(file.lastPathComponent)")
        } catch {
            completion(.failure(error))
            return nil
        }
        return process
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

    private func launch(script: URL, action: String, model: WhisperModelFile?, settings: Settings) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, action]
        process.environment = makeEnvironment(model: model, settings: settings)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    private func makeEnvironment(model: WhisperModelFile?, settings: Settings) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["DICTATE_STATE_DIR"] = Paths.state.path
        environment["HUD_BIN"] = "/nonexistent"   // окно рисует само приложение
        environment["DICTATE_NOTIFY"] = "0"
        environment["DICTATE_NO_PASTE"] = "1"     // ⌘V отправляет само приложение
        if let model {
            environment["WHISPER_MODEL"] = model.path
        }

        if let server = WhisperModelStore.bundledServer {
            environment["WHISPER_SERVER_BIN"] = server.path
        }
        if let cli = WhisperModelStore.bundledCLI {
            environment["WHISPER_CLI_BIN"] = cli.path
        }
        if let vad = WhisperModelStore.bundledVAD {
            environment["WHISPER_VAD_MODEL"] = vad.path
        }
        if !settings.microphone.isEmpty {
            environment["MIC_NAME"] = settings.microphone
        }

        // Не даём унаследованным из shell переменным смешиваться с выбранным профилем.
        for key in ["OC_PROVIDER", "OC_MODEL_ID", "OC_BASE_URL",
                    "OC_API_KEY", "OC_VARIANT", "DICTATE_USE_OC",
                    "DICTATE_AI_KIND"] {
            environment.removeValue(forKey: key)
        }

        if let provider = settings.dictationProvider {
            environment["OC_MODEL_ID"] = provider.model
            switch provider.kind {
            case .opencode:
                environment["DICTATE_USE_OC"] = "1"
                environment["DICTATE_AI_KIND"] = "opencode"
                environment["OC_PROVIDER"] = provider.providerID
            case .openai, .anthropic:
                let baseURL = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                if let safeURL = try? AIProviderURL.validateBase(baseURL) {
                    environment["DICTATE_USE_OC"] = "1"
                    environment["DICTATE_AI_KIND"] = provider.kind.rawValue
                    environment["OC_BASE_URL"] = safeURL
                    if let key = Keychain.value(for: provider.keychainAccount), !key.isEmpty {
                        environment["OC_API_KEY"] = key
                            .replacingOccurrences(of: "\r", with: "")
                            .replacingOccurrences(of: "\n", with: "")
                    }
                } else {
                    environment["DICTATE_USE_OC"] = "0"
                    Log.write("dictation: небезопасный base URL — без AI")
                }
            }
            Log.write("dictation profile: \(provider.name), \(provider.kind.rawValue), model=\(provider.model)")
        } else {
            environment["DICTATE_USE_OC"] = "0"
            Log.write("dictation profile: без AI (сырой текст)")
        }

        let forwarded: [(String, String?)] = [
            ("DICTATE_PROMPT_FIX", settings.promptFix.isEmpty ? nil : settings.promptFix),
            ("WHISPER_LANG", settings.language.isEmpty ? nil : settings.language),
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

extension DictationRunner.Failure: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .missingScript:
            return "В ресурсах приложения не найден dictate.sh"
        case .missingModel:
            return "Модель Whisper не выбрана — откройте Настройки → Распознавание"
        case .emptyTranscription:
            return "Речь не распознана — возможно, в файле тишина или музыка."
        case .transcription(let message):
            return message
        }
    }
}
