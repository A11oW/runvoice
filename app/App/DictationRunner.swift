import Foundation

/// Запускает bin/dictate.sh с окружением, собранным из настроек приложения.
final class DictationRunner {
    private var activePipeline: Process?
    enum Failure: Swift.Error {
        case missingScript
        case missingModel(path: String?)
    }

    func run(completion: (() -> Void)? = nil) throws {
        guard let script = Paths.script else { throw Failure.missingScript }

        let settings = SettingsStore.load()
        guard let model = WhisperModelStore.activeModel(settings: settings) else {
            throw Failure.missingModel(path: settings.whisperModelPath.isEmpty ? nil : settings.whisperModelPath)
        }
        try launch(script: script, action: "toggle", model: model, settings: settings, completion: completion)
    }

    /// GUI уже записал WAV; готовый потоковый текст пропускает повторный ASR.
    func finish(audio: URL, transcript: String?, settings: Settings,
                completion: @escaping () -> Void) throws {
        guard let script = Paths.script else { throw Failure.missingScript }
        let model = WhisperModelStore.activeModel(settings: settings)
        if transcript == nil, model == nil { throw Failure.missingModel(path: nil) }
        var arguments = [audio.path]
        if let transcript {
            let url = audio.deletingPathExtension().appendingPathExtension("txt")
            try transcript.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            arguments.append(url.path)
        }
        try launch(script: script, action: "finish", model: model, settings: settings,
                   arguments: arguments, modelName: transcript == nil ? nil : "Nemotron Multilingual 0.6B",
                   completion: completion)
    }

    /// Немедленная отмена текущей записи без распознавания и вставки.
    func cancel() throws {
        guard let script = Paths.script else { throw Failure.missingScript }
        let settings = SettingsStore.load()
        try launch(script: script, action: "cancel", model: nil, settings: settings)
    }

    func stopProcessing() {
        if activePipeline?.isRunning == true { activePipeline?.terminate() }
        activePipeline = nil
    }

    /// Прогрев whisper-server после сохранения настроек.
    /// Не блокирует UI: скрипт запускается в фоне и сам ждёт готовности сервера.
    func warmUp(settings: Settings? = nil, completion: (() -> Void)? = nil) {
        guard let script = Paths.script else { return }
        let settings = settings ?? SettingsStore.load()
        guard let model = WhisperModelStore.activeModel(settings: settings) else { return }
        do {
            try launch(script: script, action: "warmup", model: model, settings: settings, completion: completion)
            Log.write("warmup: запущен")
        } catch {
            Log.write("warmup: не удалось запустить (\(error.localizedDescription))")
        }
    }

    private func launch(script: URL, action: String, model: WhisperModelFile?, settings: Settings,
                        arguments: [String] = [], modelName: String? = nil,
                        completion: (() -> Void)? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, action] + arguments
        process.environment = makeEnvironment(model: model, settings: settings,
                                               needsAI: action != "warmup" && action != "cancel")
        if let modelName { process.environment?["DICTATE_MODEL_NAME"] = modelName }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                if self?.activePipeline === finished { self?.activePipeline = nil }
                completion?()
            }
        }
        try process.run()
        if action == "finish" { activePipeline = process }
    }

    private func makeEnvironment(model: WhisperModelFile?, settings: Settings, needsAI: Bool) -> [String: String] {
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

        if needsAI, let provider = settings.dictationProvider {
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
            if needsAI { Log.write("dictation profile: без AI (сырой текст)") }
        }

        let vocabulary = SpeechVocabulary.prompt(settings.speechVocabulary)
        var fixPrompt = settings.promptFix.isEmpty ? DefaultPrompts.fix : settings.promptFix
        if !vocabulary.isEmpty {
            fixPrompt += "\nТехнические термины: \(vocabulary). Если эти названия произнесены, сохрани их написание. Не добавляй отсутствующие в речи термины."
        }
        let forwarded: [(String, String?)] = [
            ("DICTATE_PROMPT_FIX", fixPrompt),
            ("WHISPER_LANG", settings.language.isEmpty ? nil : settings.language),
            ("WHISPER_PROMPT", vocabulary),
            ("DICTATE_RESTORE_CLIPBOARD", settings.restoreClipboard ? "1" : nil),
        ]
        for (key, value) in forwarded {
            environment[key] = value
        }

        let base = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = base + ":" + (environment["PATH"] ?? "")
        return environment
    }
}
