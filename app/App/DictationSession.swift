import Foundation

/// Модель и язык фиксируются на всю диктовку. Файл WAV остаётся резервом
/// до окончания конвейера; частичные гипотезы никогда не вставляются в поле.
final class DictationSession {
    var onTranscript: ((String) -> Void)?
    var onSpectrum: (([CGFloat]) -> Void)?
    private let spectrum = AudioSpectrumAnalyzer()
    private let recorder: DictationAudioRecording
    private let fluid: FluidSpeechClient
    private let runner: DictationPipeline
    private let live: LiveTranscriber
    private let loadSettings: () -> Settings
    private var settings = Settings()
    private var generation = UUID()
    private var audioURL: URL?
    private var phase = "idle"
    private var pauseRequested = false
    private var transition = UUID()
    private var previewNeedsRestart = false
    private var latestFluidPartial = ""
    private var warmGeneration = UUID()
    private var warmTask: URLSessionDataTask?
    private var warmedModel = ""
    private var session: URLSession
    var isBusy: Bool { phase != "idle" }
    var recordingSessionID: UUID? {
        ["recording", "pausing", "paused", "resuming"].contains(phase) ? generation : nil
    }
    var pausedSessionID: UUID? { pauseRequested ? recordingSessionID : nil }
    var isRecording: Bool { phase == "recording" && !pauseRequested }

    init(runner: DictationPipeline, recorder: DictationAudioRecording = NativeAudioRecorder(),
         fluid: FluidSpeechClient = FluidSpeechClient(), live: LiveTranscriber? = nil,
         loadSettings: @escaping () -> Settings = SettingsStore.load) {
        self.runner = runner
        self.recorder = recorder
        self.fluid = fluid
        self.loadSettings = loadSettings
        let configured = Int(ProcessInfo.processInfo.environment["WHISPER_SERVER_PORT"] ?? "") ?? 8799
        let port = (1...65535).contains(configured) ? configured : 8799
        self.live = live ?? LiveTranscriber(directory: Paths.state, serverURL: URL(string: "http://127.0.0.1:\(port)")!)
        session = URLSession(configuration: .ephemeral)
        self.live.onUpdate = { [weak self] text in
            guard let self, self.recordingSessionID != nil, self.settings.showsRecognitionPreview else { return }
            self.onTranscript?(text)
        }
        self.live.onNeedsServer = { [weak self] in
            guard let self else { return }
            self.runner.warmUp(settings: self.settings, completion: nil)
        }
        self.live.onTiming = { timing in
            Log.write("performance: preview_request_ms=\(timing.requestMS) preview_stabilize_ms=\(timing.stabilizationMS) preview_gap_ms=\(timing.updateGapMS.map(String.init) ?? "-") preview_result=\(timing.outcome.rawValue)")
        }
        fluid.onPartial = { [weak self] text in
            guard let self, self.recordingSessionID != nil else { return }
            self.latestFluidPartial = text
            guard self.settings.showsRecognitionPreview else { return }
            self.onTranscript?(text)
        }
        fluid.onFailure = { [weak self] in
            guard let self, self.isBusy else { return }
            Log.write("ASR: \(self.settings.fluidModel.rawValue) fallback to Whisper (full WAV)")
            self.previewNeedsRestart = true
            if self.isRecording { self.startWhisperPreview() }
        }
    }

    func toggle() throws {
        if recordingSessionID != nil { stop(); return }
        guard phase == "idle" else { return }
        let settings = loadSettings()
        let useFluid = settings.recognitionTechnology == .fluidAudio && FluidModelStore.supported
        if useFluid {
            guard FluidModelStore.installed(settings.fluidModel) else { throw Failure.missingFluidModel(settings.fluidModel) }
        } else if WhisperModelStore.activeModel(settings: settings) == nil {
            throw DictationRunner.Failure.missingModel(path: settings.whisperModelPath.isEmpty ? nil : settings.whisperModelPath)
        }
        self.settings = settings
        pauseRequested = false; transition = UUID(); previewNeedsRestart = false; latestFluidPartial = ""
        spectrum.reset()
        warmGeneration = UUID(); warmTask?.cancel(); warmTask = nil
        generation = UUID()
        let token = generation
        let url = Paths.state.appendingPathComponent("capture-\(token.uuidString).wav")
        audioURL = url
        try? FileManager.default.removeItem(at: Paths.lastResult)
        phase = "preparing"
        status("preparing")
        if useFluid { fluid.start(model: settings.fluidModel, language: settings.language, vocabulary: settings.speechVocabulary) }
        recorder.onAudio = { [weak self] pcm in
            guard let self, self.generation == token,
                  self.phase != "idle" else { return }
            if useFluid, self.fluid.healthy, self.settings.fluidModel == .nemotron { self.fluid.append(pcm) }
            else { self.live.append(pcm) }
            if self.isRecording, let levels = self.spectrum.consume(pcm) {
                self.onSpectrum?(levels)
            }
        }
        recorder.onFailure = { [weak self] error in
            guard let self, self.generation == token, self.phase != "idle" else { return }
            self.cancel(message: error.localizedDescription, error: true)
        }
        if useFluid, fluid.healthy, settings.fluidModel.usesWindowedRecognition { startParakeetPreview() }
        else if !useFluid || !fluid.healthy { startWhisperPreview() }
        recorder.start(microphone: settings.microphone, deviceUID: settings.microphoneUID, url: url) { [weak self] result in
            guard let self, self.generation == token else { return }
            switch result {
            case .success:
                self.phase = "recording"
                self.status("recording")
                Log.write("capture: native PCM16/16000 started technology=\(settings.recognitionTechnology.rawValue) model=\(useFluid ? settings.fluidModel.rawValue : "whisper")")
            case .failure(let error): self.fail(error)
            }
        }
    }

    private func startWhisperPreview() {
        guard settings.showsRecognitionPreview,
              let model = WhisperModelStore.activeModel(settings: settings) else { return }
        live.start(modelPath: model.path, language: settings.language,
                   vocabulary: settings.speechVocabulary, inMemory: true)
        previewNeedsRestart = false
    }

    private func startParakeetPreview() {
        guard settings.showsRecognitionPreview else { return }
        live.start(modelPath: settings.fluidModel.rawValue, language: settings.language, inMemory: true,
                   recognizer: { [weak self] pcm, completion in
                       guard let self else { completion(.failure(URLError(.cancelled))); return {} }
                       return self.fluid.preview(pcm, completion: completion)
                   })
        previewNeedsRestart = false
    }

    /// Настройки интерфейса применяются после сохранения, без смены модели
    /// или языка уже начатой диктовки. Поток Nemotron нужен и для финального ASR.
    func updatePreviewSettings(_ saved: Settings) {
        let wasVisible = settings.showsRecognitionPreview
        settings.previewEnabled = saved.previewEnabled
        settings.previewLineCount = saved.previewLineCount
        guard recordingSessionID != nil || phase == "preparing" else { return }
        if !settings.showsRecognitionPreview { live.stop() }
        else if !wasVisible {
            guard phase == "recording" || phase == "preparing" else { previewNeedsRestart = true; return }
            if settings.recognitionTechnology == .fluidAudio, fluid.healthy {
                if settings.fluidModel.usesWindowedRecognition { startParakeetPreview() }
            } else { startWhisperPreview() }
        }
    }

    /// Физические нажатия меняют желаемое состояние; переходы I/O идут по одному.
    @discardableResult
    func togglePause(expectedSessionID: UUID) -> Bool {
        guard recordingSessionID == expectedSessionID else { return false }
        pauseRequested.toggle()
        reconcilePause()
        return true
    }

    private func reconcilePause() {
        let token = generation
        let operation = UUID()
        if phase == "recording", pauseRequested {
            phase = "pausing"; transition = operation
            live.pause()
            recorder.pause { [weak self] result in
                guard let self, self.generation == token, self.transition == operation,
                      self.phase == "pausing" else { return }
                switch result {
                case .failure(let error): self.cancel(message: error.localizedDescription, error: true)
                case .success:
                    self.phase = "paused"
                    self.spectrum.reset()
                    self.status("paused")
                    if self.settings.recognitionTechnology == .fluidAudio, self.fluid.healthy,
                       self.settings.fluidModel == .nemotron {
                        self.fluid.finishPausedAudio()
                    } else if self.settings.showsRecognitionPreview {
                        self.live.finishPausedAudio(audioURL: self.audioURL)
                    }
                    self.reconcilePause()
                }
            }
        } else if phase == "paused", !pauseRequested {
            phase = "resuming"; transition = operation
            recorder.resume { [weak self] result in
                guard let self, self.generation == token, self.transition == operation,
                      self.phase == "resuming" else { return }
                switch result {
                case .failure(let error): self.cancel(message: error.localizedDescription, error: true)
                case .success:
                    self.phase = "recording"
                    self.spectrum.reset()
                    if self.pauseRequested { self.reconcilePause(); return }
                    if self.previewNeedsRestart {
                        if self.settings.recognitionTechnology == .fluidAudio, self.fluid.healthy {
                            if self.settings.fluidModel.usesWindowedRecognition { self.startParakeetPreview() }
                        } else { self.startWhisperPreview() }
                    } else { self.live.resume() }
                    self.status("recording")
                    if self.settings.showsRecognitionPreview, self.fluid.healthy, !self.latestFluidPartial.isEmpty {
                        self.onTranscript?(self.latestFluidPartial)
                    }
                }
            }
        }
    }

    /// Enter завершает только ту запись, для которой было перехвачено нажатие.
    @discardableResult
    func finishRecording(expectedSessionID: UUID) -> Bool {
        guard recordingSessionID == expectedSessionID else { return false }
        stop()
        return true
    }

    /// Отложенный Esc не может отменить уже начатую обработку или новую запись.
    @discardableResult
    func cancelRecording(expectedSessionID: UUID) -> Bool {
        guard recordingSessionID == expectedSessionID else { return false }
        cancel()
        return true
    }

    private func stop() {
        transition = UUID(); pauseRequested = false
        phase = "transcribing"
        live.stop()
        status("transcribing")
        let token = generation
        let start = Date()
        recorder.stop(discard: false) { [weak self] result in
            guard let self, self.generation == token else { return }
            switch result {
            case .failure(let error): self.fail(error)
            case .success(let recording):
                Log.write("performance: capture_stop_ms=\(Int(Date().timeIntervalSince(start) * 1000)) frames=\(recording.frames)")
                if self.settings.recognitionTechnology == .fluidAudio, self.fluid.healthy {
                    self.fluid.finish(audio: recording.url) { [weak self] text in
                        guard let self, self.generation == token else { return }
                        self.process(recording.url, transcript: text, token: token)
                    }
                } else { self.process(recording.url, transcript: nil, token: token) }
            }
        }
    }

    private func process(_ audio: URL, transcript: String?, token: UUID) {
        do {
            try runner.finish(audio: audio, transcript: transcript, settings: settings) { [weak self] in
                guard let self, self.generation == token else { return }
                self.phase = "idle"
                self.removeAudio()
                // Shell обязан опубликовать done/error. Защита от аварийного выхода.
                if let raw = try? String(contentsOf: Paths.status, encoding: .utf8),
                   ["transcribing", "fixing"].contains(DictationState(raw: raw)?.key ?? "") {
                    self.status("error", "Распознавание завершилось без результата")
                }
            }
        } catch DictationRunner.Failure.missingModel(_) {
            fail(Failure.missingWhisperModel(isBackup: settings.recognitionTechnology == .fluidAudio))
        } catch { fail(error) }
    }

    func cancel(message: String = "Запись отменена", error: Bool = false) {
        guard phase == "preparing" || recordingSessionID != nil || error else { return }
        generation = UUID()
        transition = UUID(); pauseRequested = false
        live.stop(); fluid.cancel()
        phase = "idle"
        let url = audioURL; audioURL = nil
        recorder.stop(discard: true) { _ in
            if let url { try? FileManager.default.removeItem(at: url) }
        }
        spectrum.reset()
        onSpectrum?([CGFloat](repeating: 0, count: AudioSpectrumAnalyzer.bandCount))
        status(error ? "error" : "info", message)
    }

    func prewarm() {
        guard !isBusy else { return }
        let saved = SettingsStore.load()
        if saved.recognitionTechnology == .fluidAudio, FluidModelStore.supported {
            fluid.warmUp(model: saved.fluidModel)
            return
        }
        fluid.unload()
        let token = UUID(); warmGeneration = token
        runner.warmUp(settings: saved) { [weak self] in
            guard let self, self.warmGeneration == token, !self.isBusy,
                  let model = WhisperModelStore.activeModel(settings: saved),
                  self.warmedModel != model.path,
                  let marker = try? String(contentsOf: Paths.state.appendingPathComponent("whisper-server.model"), encoding: .utf8),
                  marker.components(separatedBy: "|").first == model.path,
                  let sample = Bundle.main.resourceURL?.appendingPathComponent("warmup.wav"),
                  let wav = try? Data(contentsOf: sample) else { return }
            let boundary = "Runvoice-" + UUID().uuidString
            var body = Data()
            for (key, value) in [("response_format", "json"), ("language", saved.language), ("no_timestamps", "true")] {
                body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n".utf8))
            }
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"warmup.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
            body.append(wav); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
            let configured = Int(ProcessInfo.processInfo.environment["WHISPER_SERVER_PORT"] ?? "") ?? 8799
            let port = (1...65535).contains(configured) ? configured : 8799
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/inference")!)
            request.httpMethod = "POST"; request.httpBody = body; request.timeoutInterval = 30
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.setValue("close", forHTTPHeaderField: "Connection")
            let task = self.session.dataTask(with: request) { [weak self] _, response, error in
                DispatchQueue.main.async {
                    guard let self, self.warmGeneration == token else { return }
                    self.warmTask = nil
                    if error == nil, (response as? HTTPURLResponse)?.statusCode == 200 {
                        self.warmedModel = model.path
                        Log.write("warmup: inference ready")
                    }
                }
            }
            self.warmTask = task; task.resume()
        }
    }

    func wake() {
        warmedModel = ""
        guard !isBusy else { return }
        fluid.unload(); prewarm()
    }
    func shutdown() {
        if phase == "preparing" || recordingSessionID != nil { cancel() }
        generation = UUID(); transition = UUID()
        warmTask?.cancel(); live.stop(); fluid.unload()
        runner.stopProcessing()
        removeAudio()
    }
    private func fail(_ error: Error) {
        live.stop(); fluid.cancel(); phase = "idle"; removeAudio()
        status("error", error.localizedDescription)
    }
    private func removeAudio() {
        guard let audioURL else { return }
        try? FileManager.default.removeItem(at: audioURL)
        try? FileManager.default.removeItem(at: audioURL.deletingPathExtension().appendingPathExtension("txt"))
        self.audioURL = nil
    }
    private func status(_ state: String, _ message: String = "") {
        try? (state + (message.isEmpty ? "" : "|" + message)).write(to: Paths.status, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Paths.status.path)
    }
    enum Failure: LocalizedError {
        case missingFluidModel(FluidModel)
        case missingWhisperModel(isBackup: Bool)
        var errorDescription: String? {
            switch self {
            case .missingFluidModel(let model): return "Скачайте \(model.title) в «Настройки» → «Распознавание» → FluidAudio"
            case .missingWhisperModel(let isBackup):
                return isBackup
                    ? "Распознавание FluidAudio не удалось. Настройте резервную модель Whisper в «Распознавании»"
                    : "Модель Whisper недоступна. Выберите её в «Распознавании»"
            }
        }
    }
}
