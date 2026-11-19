import Foundation

/// Координатор работает на main, сеть и тяжёлые операции — в собственных очередях.
final class LocalAPIService {
    static let shared = LocalAPIService()
    typealias Corrector = (String, Settings, String?, @escaping (Result<String, Error>) -> Void) -> (() -> Void)
    private var statusText = "Выключен"
    private(set) var status: String {
        get {
            if listening, let error = config.apiRecognitionModel.availabilityError(settings: config) {
                return "Ошибка: " + error
            }
            if statusText == "Готов", config.apiAudioFilterEnabled, !audioFilter.ready { return "Ошибка: VAD API недоступен" }
            return statusText == "Готов" && !engine.isReady ? "Ошибка: API-движок недоступен" : statusText
        }
        set { statusText = newValue }
    }
    private(set) var listening = false
    private let audioFilter: APIAudioFiltering
    private let engine: APIRecognitionBackend
    private let loadSettings: () -> Settings
    private let correct: Corrector
    private let requestDeadline: TimeInterval
    private var server: LocalAPIHTTPServer?
    private var config = Settings()
    private var queue: [Job] = []
    private var active: Job?
    var hasPendingWork: Bool { active != nil || !queue.isEmpty || warming }
    private var warming = false
    private var generation = UUID()
    private var readyProfile: String?
    private var readyTechnology: String?
    private var readyModel: String?

    var loadedModelDescription: String? {
        guard engine.isReady, let technology = readyTechnology, let model = readyModel else { return nil }
        return (technology == RecognitionTechnology.whisper.rawValue ? "Whisper" : "FluidAudio") + " · " + model
    }

    private final class Job {
        let id: UUID
        let pcm: Data
        let completion: (Int, [String: Any]) -> Void
        var timeout: DispatchWorkItem?
        var cancelAI: (() -> Void)?
        init(id: UUID, pcm: Data, completion: @escaping (Int, [String: Any]) -> Void) {
            self.id = id; self.pcm = pcm; self.completion = completion
        }
    }

    init(engine: APIRecognitionBackend = APIRecognitionEngine(), audioFilter: APIAudioFiltering = APIAudioFilter(), loadSettings: @escaping () -> Settings = SettingsStore.load,
         requestDeadline: TimeInterval = 85, correct: @escaping Corrector = { text, settings, apiKey, completion in
             guard let provider = settings.dictationProvider else {
                 completion(.failure(LocalAPIError(503, "Не выбран профиль AI-правки диктовки"))); return {}
             }
             return AIClient.generate(provider: provider, system: settings.dictationFixPrompt, text: text,
                                      apiKey: apiKey, logDetails: false, completion: completion)
         }) {
        self.audioFilter = audioFilter; self.engine = engine; self.loadSettings = loadSettings; self.requestDeadline = requestDeadline; self.correct = correct
    }

    static func validPort(_ value: Int) -> Bool { (1...65535).contains(value) && ![8798, 8799].contains(value) }
    static func endpoint(port: Int) -> String { "http://127.0.0.1:\(port)\(LocalAPIWire.transcriptionPath)" }
    static func modelName(_ source: Settings) -> String {
        let settings = source.apiRecognitionSettings
        if settings.recognitionTechnology == .fluidAudio { return settings.fluidModel.title }
        let model = WhisperModelStore.activeModel(settings: settings)
        return model?.catalogModel?.title ?? model?.fileName ?? "Модель не выбрана"
    }
    private static func profile(_ source: Settings) -> String {
        let settings = source.apiRecognitionSettings
        let model = settings.recognitionTechnology == .whisper
            ? (WhisperModelStore.activeModel(settings: settings)?.path ?? settings.whisperModelPath)
            : settings.fluidModel.rawValue
        return [settings.recognitionTechnology.rawValue, model, settings.language,
                SpeechVocabulary.prompt(settings.speechVocabulary)].joined(separator: "|")
    }

    func configure(_ settings: Settings) {
        let restart = config.apiPort != settings.apiPort || config.apiEnabled != settings.apiEnabled || server == nil
        let changed = Self.profile(config) != Self.profile(settings)
            || config.apiAudioFilterEnabled != settings.apiAudioFilterEnabled
        if !settings.apiAudioFilterEnabled, active == nil { audioFilter.stop() }
        config = settings
        guard settings.apiEnabled else { stop(); return }
        guard Self.validPort(settings.apiPort) else { stop(); status = "Ошибка: недопустимый или внутренний порт"; return }
        if restart {
            stop()
            let server = LocalAPIHTTPServer()
            self.server = server
            status = "Запускается…"
            server.onState = { [weak self, weak server] state in
                guard let self, self.server === server else { return }
                if state == "listening" { self.listening = true; self.warmWhenIdle() }
                else { self.stop(); self.status = "Ошибка запуска: порт занят или недоступен" }
            }
            server.onRequest = { [weak self, weak server] request, reply in
                let id = UUID()
                DispatchQueue.main.async {
                    guard let self, self.server === server else { reply(503, ["error": ["message": "API остановлен"]]); return }
                    self.receive(id: id, request: request, completion: reply)
                }
                return { DispatchQueue.main.async { self?.cancel(id: id) } }
            }
            do { try server.start(port: UInt16(settings.apiPort)) }
            catch { stop(); status = "Ошибка запуска локального API" }
        } else if changed, active == nil {
            generation = UUID(); warming = false; readyProfile = nil; engine.shutdown()
            warmWhenIdle()
        }
    }

    func stop() {
        generation = UUID()
        let pending = queue + (active.map { [$0] } ?? [])
        queue.removeAll(); active = nil
        for job in pending {
            job.timeout?.cancel(); job.cancelAI?()
            job.completion(503, ["error": ["message": "Локальный API остановлен"]])
        }
        server?.stop(); server = nil
        engine.shutdown(); audioFilter.stop()
        warming = false; listening = false; readyProfile = nil; readyTechnology = nil; readyModel = nil
        status = "Выключен"
    }

    private func warmWhenIdle() {
        guard listening, active == nil, !warming else { return }
        if !queue.isEmpty { drain(); return }
        let source = loadSettings()
        if let error = source.apiRecognitionModel.availabilityError(settings: source) {
            readyProfile = nil; status = "Ошибка: " + error; return
        }
        let settings = source.apiRecognitionSettings
        warming = true; status = "Прогревается…"
        let token = generation
        prepare(settings) { [weak self] result in
            guard let self, self.generation == token else { return }
            self.warming = false
            switch result {
            case .success:
                self.markReady(settings)
            case .failure(let error): self.readyProfile = nil; self.status = "Ошибка прогрева: " + ((error as? LocalAPIError)?.message ?? "API-движок недоступен")
            }
            self.drain()
        }
    }

    private func prepare(_ settings: Settings, completion: @escaping (Result<Void, Error>) -> Void) {
        engine.prepare(settings: settings) { [weak self] result in
            guard let self else { return }
            guard case .success = result, settings.apiAudioFilterEnabled else { completion(result); return }
            self.audioFilter.prepare(completion)
        }
    }

    private func markReady(_ settings: Settings) {
        readyProfile = Self.profile(settings)
        readyTechnology = settings.recognitionTechnology.rawValue
        readyModel = Self.modelName(settings)
        status = "Готов"
    }

    func health() -> [String: Any] {
        let source = loadSettings()
        let settings = source.apiRecognitionSettings
        let ready = listening && engine.isReady && (!settings.apiAudioFilterEnabled || audioFilter.ready) && readyProfile == Self.profile(settings)
            && source.apiRecognitionModel.availabilityError(settings: source) == nil
            && (!settings.apiImproveText || settings.dictationProvider != nil)
        return ["status": ready ? "ready" : (warming || active != nil ? "warming" : "unavailable"),
                "technology": ready ? (readyTechnology ?? "") : settings.recognitionTechnology.rawValue,
                "model": ready ? (readyModel ?? "") : Self.modelName(settings),
                "ai_enabled": settings.apiImproveText, "queued": queue.count, "busy": active != nil]
    }

    private func receive(id: UUID, request: LocalAPIRequest, completion: @escaping (Int, [String: Any]) -> Void) {
        guard !UpdateCoordinator.shared.isInstalling else { completion(503, ["error": ["message": "Runvoice устанавливает обновление"]]); return }
        guard listening else { completion(503, ["error": ["message": "Локальный API не запущен"]]); return }
        if request.path == LocalAPIWire.healthPath {
            guard request.method == "GET" else { completion(405, ["error": ["message": "Требуется GET"]]); return }
            let json = health()
            completion(json["status"] as? String == "ready" ? 200 : 503, json)
            return
        }
        guard request.path == LocalAPIWire.transcriptionPath else { completion(404, ["error": ["message": "Путь не найден"]]); return }
        guard request.method == "POST" else { completion(405, ["error": ["message": "Требуется POST"]]); return }
        do {
            let pcm = try LocalAPIWire.audio(request)
            guard queue.count < 8 else { throw LocalAPIError(429, "Очередь API заполнена") }
            let remaining = requestDeadline - (ProcessInfo.processInfo.systemUptime - request.receivedAt)
            guard remaining > 0 else { throw LocalAPIError(504, "Истекло время запроса API") }
            let job = Job(id: id, pcm: pcm, completion: completion)
            let timeout = DispatchWorkItem { [weak self] in
                self?.cancel(id: id, response: LocalAPIError(504, "Истекло время запроса API"))
            }
            job.timeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: timeout)
            queue.append(job); drain()
        } catch let error as LocalAPIError { completion(error.status, ["error": ["message": error.message]]) }
        catch { completion(400, ["error": ["message": "Некорректный запрос API"]]) }
    }

    private func drain() {
        guard listening, active == nil, !warming, !queue.isEmpty else { return }
        let job = queue.removeFirst(); active = job
        let source = loadSettings()
        if let error = source.apiRecognitionModel.availabilityError(settings: source) {
            finish(job, .failure(LocalAPIError(503, error))); return
        }
        let settings = source.apiRecognitionSettings
        if settings.apiImproveText && settings.dictationProvider == nil {
            finish(job, .failure(LocalAPIError(503, "Выберите профиль AI-правки диктовки или отключите правку API"))); return
        }
        let apiKey: String? = settings.apiImproveText && settings.dictationProvider?.kind.usesAPIKey == true
            ? (Keychain.value(for: settings.dictationProvider!.keychainAccount) ?? "") : nil
        status = engine.isReady && readyProfile == Self.profile(settings) ? "Распознаёт…" : "Прогревается…"
        prepare(settings) { [weak self, weak job] result in
            guard let self, let job, self.active === job else { return }
            guard case .success = result else {
                if case .failure(let error) = result { self.finish(job, .failure(error)) }; return
            }
            self.markReady(settings)
            self.status = "Распознаёт…"
            // Цифровая тишина — в том числе проверка подключения ktalk-assist.
            if job.pcm.allSatisfy({ $0 == 0 }) { self.finish(job, .success("")); return }
            let recognize: (Result<Data, Error>) -> Void = { [weak self, weak job] filtered in
                guard let self, let job, self.active === job else { return }
                guard case .success(let pcm) = filtered else {
                    self.finish(job, .failure(LocalAPIError(503, "Ошибка VAD-фильтра API"))); return
                }
                if pcm.isEmpty { self.finish(job, .success("")); return }
                self.engine.transcribe(pcm: pcm, settings: settings) { [weak self, weak job] result in
                    guard let self, let job, self.active === job else { return }
                    switch result {
                    case .failure: self.finish(job, .failure(LocalAPIError(503, "Ошибка выбранного движка распознавания API")))
                    case .success(let text):
                        guard settings.apiImproveText, !text.isEmpty else { self.finish(job, .success(text)); return }
                        self.status = "AI-правка…"
                        job.cancelAI = self.correct(text, settings, apiKey) { [weak self, weak job] result in
                            DispatchQueue.main.async {
                                guard let self, let job, self.active === job else { return }
                                switch result {
                                case .success(let corrected): self.finish(job, .success(corrected))
                                case .failure: self.finish(job, .failure(LocalAPIError(502, "Ошибка AI-правки API")))
                                }
                            }
                        }
                    }
                }
            }
            if settings.apiAudioFilterEnabled {
                self.status = "Проверяет речь…"
                self.audioFilter.apply(job.pcm, settings: settings, completion: recognize)
            } else { recognize(.success(job.pcm)) }
        }
    }

    private func finish(_ job: Job, _ result: Result<String, Error>) {
        guard active === job else { return }
        job.timeout?.cancel(); job.cancelAI = nil; active = nil
        if !loadSettings().apiAudioFilterEnabled { audioFilter.stop() }
        switch result {
        case .success(let text): job.completion(200, ["text": text.trimmingCharacters(in: .whitespacesAndNewlines)]); status = "Готов"
        case .failure(let error):
            let failure = error as? LocalAPIError ?? LocalAPIError(503, "Ошибка API")
            job.completion(failure.status, ["error": ["message": failure.message]])
            engine.shutdown(); audioFilter.stop(); readyProfile = nil; status = "Ошибка запроса API"
        }
        if !queue.isEmpty { drain() }
        else if readyProfile != Self.profile(loadSettings()) || (loadSettings().apiAudioFilterEnabled && !audioFilter.ready) { warmWhenIdle() }
    }

    func cancel(id: UUID, response: LocalAPIError? = nil) {
        if let index = queue.firstIndex(where: { $0.id == id }) {
            let job = queue.remove(at: index); job.timeout?.cancel()
            if let response { job.completion(response.status, ["error": ["message": response.message]]) }
        } else if let job = active, job.id == id {
            active = nil; job.timeout?.cancel(); job.cancelAI?()
            engine.shutdown(); audioFilter.stop(); readyProfile = nil
            if let response { job.completion(response.status, ["error": ["message": response.message]]) }
            status = "Запрос отменён"
            if !queue.isEmpty { drain() }
        }
    }
}
