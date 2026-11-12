import Foundation

/// Модель и язык фиксируются на всю диктовку. Файл WAV остаётся резервом
/// до окончания конвейера; частичные гипотезы никогда не вставляются в поле.
final class DictationSession {
    var onTranscript: ((String) -> Void)?
    var onSpectrum: (([CGFloat]) -> Void)?
    private let spectrum = AudioSpectrumAnalyzer()
    private let recorder = NativeAudioRecorder()
    private let fluid = FluidSpeechClient()
    private let runner: DictationRunner
    private let live: LiveTranscriber
    private var settings = Settings()
    private var generation = UUID()
    private var audioURL: URL?
    private var phase = "idle"
    private var warmGeneration = UUID()
    private var warmTask: URLSessionDataTask?
    private var warmedModel = ""
    private var session: URLSession
    var isBusy: Bool { phase != "idle" }
    var recordingSessionID: UUID? { phase == "recording" ? generation : nil }

    init(runner: DictationRunner) {
        self.runner = runner
        let configured = Int(ProcessInfo.processInfo.environment["WHISPER_SERVER_PORT"] ?? "") ?? 8799
        let port = (1...65535).contains(configured) ? configured : 8799
        live = LiveTranscriber(directory: Paths.state, serverURL: URL(string: "http://127.0.0.1:\(port)")!)
        session = URLSession(configuration: .ephemeral)
        live.onUpdate = { [weak self] text in
            guard let self, self.settings.showsRecognitionPreview else { return }
            self.onTranscript?(text)
        }
        live.onNeedsServer = { [weak self] in
            guard let self else { return }
            self.runner.warmUp(settings: self.settings)
        }
        fluid.onPartial = { [weak self] text in
            guard let self, self.phase == "recording", self.settings.showsRecognitionPreview else { return }
            self.onTranscript?(text)
        }
        fluid.onFailure = { [weak self] in
            guard let self, self.isBusy else { return }
            Log.write("streaming: fallback to Whisper (full WAV)")
            if self.phase == "recording" { self.startWhisperPreview() }
        }
    }

    func toggle() throws {
        if phase == "recording" { stop(); return }
        guard phase == "idle" else { return }
        let settings = SettingsStore.load()
        let useFluid = settings.recognitionEngine == "nemotron" && FluidModelStore.supported
        if useFluid {
            guard FluidModelStore.supported, FluidModelStore.installed else { throw Failure.missingStreamingModel }
        } else if WhisperModelStore.activeModel(settings: settings) == nil {
            throw DictationRunner.Failure.missingModel(path: settings.whisperModelPath.isEmpty ? nil : settings.whisperModelPath)
        }
        self.settings = settings
        spectrum.reset()
        warmGeneration = UUID(); warmTask?.cancel(); warmTask = nil
        generation = UUID()
        let token = generation
        let url = Paths.state.appendingPathComponent("capture-\(token.uuidString).wav")
        audioURL = url
        try? FileManager.default.removeItem(at: Paths.lastResult)
        phase = "preparing"
        status("preparing")
        if useFluid { fluid.start(language: settings.language, vocabulary: settings.speechVocabulary) }
        recorder.onAudio = { [weak self] pcm in
            guard let self, self.generation == token,
                  ["preparing", "recording", "transcribing"].contains(self.phase) else { return }
            if useFluid, self.fluid.healthy { self.fluid.append(pcm) }
            else { self.live.append(pcm) }
            if self.phase == "recording", let levels = self.spectrum.consume(pcm) {
                self.onSpectrum?(levels)
            }
        }
        recorder.onFailure = { [weak self] error in
            guard let self, self.generation == token, self.phase != "idle" else { return }
            self.cancel(message: error.localizedDescription, error: true)
        }
        if !useFluid || !fluid.healthy { startWhisperPreview() }
        recorder.start(microphone: settings.microphone, deviceUID: settings.microphoneUID, url: url) { [weak self] result in
            guard let self, self.generation == token else { return }
            switch result {
            case .success:
                self.phase = "recording"
                self.status("recording")
                Log.write("capture: native PCM16/16000 started engine=\(useFluid ? "nemotron" : "whisper")")
            case .failure(let error): self.fail(error)
            }
        }
    }

    private func startWhisperPreview() {
        guard settings.showsRecognitionPreview,
              let model = WhisperModelStore.activeModel(settings: settings) else { return }
        live.start(modelPath: model.path, language: settings.language,
                   vocabulary: settings.speechVocabulary, inMemory: true)
    }

    /// Настройки интерфейса применяются после сохранения, без смены модели
    /// или языка уже начатой диктовки. Поток Nemotron нужен и для финального ASR.
    func updatePreviewSettings(_ saved: Settings) {
        let wasVisible = settings.showsRecognitionPreview
        settings.previewEnabled = saved.previewEnabled
        settings.previewLineCount = saved.previewLineCount
        guard phase == "recording" || phase == "preparing" else { return }
        if !settings.showsRecognitionPreview { live.stop() }
        else if !wasVisible, settings.recognitionEngine != "nemotron" || !fluid.healthy { startWhisperPreview() }
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
        phase = "transcribing"
        live.stop()
        status("transcribing")
        let token = generation
        let start = Date()
        recorder.stop { [weak self] result in
            guard let self, self.generation == token else { return }
            switch result {
            case .failure(let error): self.fail(error)
            case .success(let recording):
                Log.write("performance: capture_stop_ms=\(Int(Date().timeIntervalSince(start) * 1000)) frames=\(recording.frames)")
                if self.settings.recognitionEngine == "nemotron", self.fluid.healthy {
                    self.fluid.finish { [weak self] text in
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
        } catch { fail(error) }
    }

    func cancel(message: String = "Запись отменена", error: Bool = false) {
        guard phase == "preparing" || phase == "recording" || error else { return }
        generation = UUID()
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
        if saved.recognitionEngine == "nemotron", FluidModelStore.supported {
            fluid.warmUp()
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
        generation = UUID()
        warmTask?.cancel(); live.stop(); fluid.unload()
        if phase == "preparing" || phase == "recording" { cancel() }
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
        case missingStreamingModel
        var errorDescription: String? { "Скачайте Nemotron Multilingual в «Настройки» → «Распознавание» (Apple Silicon)" }
    }
}
