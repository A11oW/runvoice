import Foundation

/// Независимый файловый ASR. Методы и callbacks — на main, без status диктовки.
protocol APIRecognitionBackend: AnyObject {
    var isReady: Bool { get }
    func prepare(settings: Settings, completion: @escaping (Result<Void, Error>) -> Void)
    func transcribe(pcm: Data, settings: Settings, completion: @escaping (Result<String, Error>) -> Void)
    func shutdown()
}

final class APIRecognitionEngine: APIRecognitionBackend {
    private let fluid: FluidSpeechClient
    private let serverBinary: () -> URL?
    private let vadModel: () -> URL?
    private let warmupAudio: () -> URL?
    private let backendPort: Int
    private let session = URLSession(configuration: .ephemeral)
    private var process: Process?
    private var retiringWhisper: Process?
    private var pendingPreparation: (() -> Void)?
    private var task: URLSessionDataTask?
    private var timer: Timer?
    private var signature = ""
    private var preparing: ((Result<Void, Error>) -> Void)?
    private var generation = UUID()
    private var privatePath = ""
    private var file: URL?
    private var started: TimeInterval = 0
    var isReady: Bool {
        guard !signature.isEmpty else { return false }
        return signature.hasPrefix("whisper:") ? process?.isRunning == true : fluid.ready && fluid.healthy
    }

    init(fluid: FluidSpeechClient = FluidSpeechClient(), backendPort: Int = 8798,
         serverBinary: @escaping () -> URL? = { WhisperModelStore.bundledServer },
         vadModel: @escaping () -> URL? = { WhisperModelStore.bundledVAD },
         warmupAudio: @escaping () -> URL? = { Bundle.main.resourceURL?.appendingPathComponent("warmup.wav") }) {
        self.fluid = fluid; self.backendPort = backendPort
        self.serverBinary = serverBinary; self.vadModel = vadModel; self.warmupAudio = warmupAudio
    }

    deinit {
        timer?.invalidate(); task?.cancel(); session.invalidateAndCancel()
        if process?.isRunning == true { process?.terminate() }
        if let file { try? FileManager.default.removeItem(at: file) }
    }

    private func identity(_ settings: Settings) throws -> String {
        guard settings.recognitionTechnology.isSupported else { throw LocalAPIError(503, "Выбранная технология не поддерживается на этом Mac") }
        if settings.recognitionTechnology == .fluidAudio {
            guard FluidModelStore.installed(settings.fluidModel) else { throw LocalAPIError(503, "Скачайте выбранную модель FluidAudio в Runvoice") }
            return "fluid:" + settings.fluidModel.rawValue
        }
        guard let model = WhisperModelStore.activeModel(settings: settings) else { throw LocalAPIError(503, "Выберите доступную модель Whisper в Runvoice") }
        return "whisper:" + model.path
    }

    func prepare(settings: Settings, completion: @escaping (Result<Void, Error>) -> Void) {
        let key: String
        do { key = try identity(settings) } catch { completion(.failure(error)); return }
        if signature == key, (settings.recognitionTechnology == .whisper ? process?.isRunning == true : fluid.ready && fluid.healthy) {
            completion(.success(())); return
        }
        shutdown()
        let token = generation
        preparing = completion
        if retiringWhisper?.isRunning == true {
            pendingPreparation = { [weak self] in self?.startPreparation(settings, key: key, token: token) }
            let timeout = Timer(timeInterval: 5, repeats: false) { [weak self] _ in
                guard let self, self.generation == token else { return }
                self.finishPreparation(.failure(LocalAPIError(503, "Прежний API-движок Whisper ещё не остановился")))
            }
            timer = timeout
            RunLoop.main.add(timeout, forMode: .common)
        } else {
            startPreparation(settings, key: key, token: token)
        }
    }

    private func startPreparation(_ settings: Settings, key: String, token: UUID) {
        timer?.invalidate(); timer = nil
        started = ProcessInfo.processInfo.systemUptime
        if settings.recognitionTechnology == .fluidAudio {
            fluid.warmUp(model: settings.fluidModel)
        } else {
            guard let binary = serverBinary(), let model = WhisperModelStore.activeModel(settings: settings) else {
                finishPreparation(.failure(LocalAPIError(503, "Не найден встроенный whisper-server"))); return
            }
            let child = Process()
            privatePath = "/runvoice-private-" + UUID().uuidString
            child.executableURL = binary
            child.arguments = ["-m", model.path, "--host", "127.0.0.1", "--port", String(backendPort),
                               "--request-path", privatePath, "-t", "8"]
            if let vad = vadModel() { child.arguments! += ["--vad", "-vm", vad.path] }
            child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
            child.terminationHandler = { [weak self] exited in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.retiringWhisper === exited else { return }
                    self.retiringWhisper = nil
                    let resume = self.pendingPreparation
                    self.pendingPreparation = nil
                    resume?()
                }
            }
            process = child
            do { try child.run() }
            catch { finishPreparation(.failure(LocalAPIError(503, "Не удалось запустить API-движок Whisper"))); return }
        }
        let poll = Timer(timeInterval: 0.10, repeats: true) { [weak self] _ in
            guard let self, self.generation == token else { return }
            guard ProcessInfo.processInfo.systemUptime - self.started < 75 else {
                self.finishPreparation(.failure(LocalAPIError(503, "Истекло время прогрева API-движка"))); return
            }
            if settings.recognitionTechnology == .fluidAudio {
                guard self.fluid.healthy else { self.finishPreparation(.failure(LocalAPIError(503, "Ошибка загрузки выбранной модели FluidAudio"))); return }
                if self.fluid.ready { self.signature = key; self.finishPreparation(.success(())) }
            } else {
                guard self.process?.isRunning == true else {
                    self.finishPreparation(.failure(LocalAPIError(503, "API-движок Whisper завершился: проверьте модель и порт 8798"))); return
                }
                guard self.task == nil else { return }
                // Уникальный путь исключает отправку аудио чужому серверу на занятом порту.
                var request = URLRequest(url: self.url("/health"))
                request.timeoutInterval = 1
                self.task = self.session.dataTask(with: request) { [weak self] _, response, _ in
                    DispatchQueue.main.async {
                        guard let self, self.generation == token, self.preparing != nil else { return }
                        self.task = nil
                        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
                        self.timer?.invalidate(); self.timer = nil
                        guard let audio = self.warmupAudio(), let wav = try? Data(contentsOf: audio) else {
                            self.signature = key; self.finishPreparation(.success(())); return
                        }
                        self.whisper(wav: wav, settings: settings) { [weak self] result in
                            guard let self, self.generation == token else { return }
                            if case .success = result { self.signature = key; self.finishPreparation(.success(())) }
                            else { self.finishPreparation(.failure(LocalAPIError(503, "Ошибка прогрева Whisper"))) }
                        }
                    }
                }
                self.task?.resume()
            }
        }
        timer = poll; RunLoop.main.add(poll, forMode: .common)
    }

    private func finishPreparation(_ result: Result<Void, Error>) {
        timer?.invalidate(); timer = nil
        let callback = preparing; preparing = nil
        if case .failure = result { shutdown() }
        callback?(result)
    }

    private func url(_ suffix: String) -> URL { URL(string: "http://127.0.0.1:\(backendPort)\(privatePath)\(suffix)")! }

    func transcribe(pcm: Data, settings: Settings, completion: @escaping (Result<String, Error>) -> Void) {
        if settings.recognitionTechnology == .whisper {
            whisper(wav: LiveTranscriber.wav(pcm: pcm), settings: settings, completion: completion)
            return
        }
        let token = generation
        let folder = Paths.state.appendingPathComponent("api/requests", isDirectory: true)
        let audio = folder.appendingPathComponent(UUID().uuidString + ".wav")
        file = audio
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { () -> Void in
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try LiveTranscriber.wav(pcm: pcm).write(to: audio, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: audio.path)
            }
            DispatchQueue.main.async {
                guard let self, self.generation == token else { try? FileManager.default.removeItem(at: audio); return }
                guard case .success = result else { completion(.failure(LocalAPIError(500, "Не удалось подготовить аудио для API"))); return }
                self.fluid.start(model: settings.fluidModel, language: settings.language, vocabulary: settings.speechVocabulary)
                if settings.fluidModel == .nemotron { self.fluid.append(pcm) }
                self.fluid.finish(audio: audio) { [weak self] text in
                    try? FileManager.default.removeItem(at: audio)
                    guard let self, self.generation == token else { return }
                    self.file = nil
                    if let text { completion(.success(text.trimmingCharacters(in: .whitespacesAndNewlines))) }
                    else if self.fluid.healthy { completion(.success("")) }
                    else { completion(.failure(LocalAPIError(503, "Выбранная модель FluidAudio не вернула результат"))) }
                }
            }
        }
    }

    private func whisper(wav: Data, settings: Settings, completion: @escaping (Result<String, Error>) -> Void) {
        let token = generation
        let boundary = "RunvoiceAPI-" + UUID().uuidString
        var body = Data()
        for (name, value) in [("language", settings.language.isEmpty ? "auto" : settings.language),
                              ("response_format", "json"), ("no_timestamps", "true"),
                              ("vad", settings.apiAudioFilterEnabled ? "false" : "true"),
                              ("prompt", SpeechVocabulary.prompt(settings.speechVocabulary))] {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: url("/inference"))
        request.httpMethod = "POST"; request.httpBody = body; request.timeoutInterval = 85
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("close", forHTTPHeaderField: "Connection")
        task = session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.task = nil
                guard error == nil, (response as? HTTPURLResponse)?.statusCode == 200,
                      let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let text = json["text"] as? String else {
                    completion(.failure(LocalAPIError(503, "Ошибка распознавания Whisper"))); return
                }
                completion(.success(text.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        task?.resume()
    }

    func shutdown() {
        generation = UUID(); preparing = nil; pendingPreparation = nil
        timer?.invalidate(); timer = nil
        task?.cancel(); task = nil
        if let process, process.isRunning {
            retiringWhisper = process
            process.terminate()
        }
        process = nil
        fluid.unload(); signature = ""
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil
    }
}
