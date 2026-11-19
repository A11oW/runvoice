import Foundation

/// Предварительное распознавание последних секунд PCM. Итоговую диктовку не меняет.
/// Все методы и onUpdate вызываются в главном потоке; одновременно идёт один запрос.
final class LiveTranscriber {
    /// Локальный backend получает PCM16/16 кГц и возвращает отмену запроса.
    typealias Recognizer = (Data, @escaping (Result<String, Error>) -> Void) -> (() -> Void)
    var onUpdate: ((String) -> Void)?
    var onNeedsServer: (() -> Void)?
    var onTiming: ((Timing) -> Void)?

    /// Только числовая диагностика; аудио и распознанные слова сюда не попадают.
    struct Timing {
        enum Outcome: String { case published, unchanged, failed }
        let requestMS: Int
        let stabilizationMS: Int
        let updateGapMS: Int?
        let outcome: Outcome
    }

    private let directory: URL
    private let serverURL: URL
    private let session: URLSession
    private let ownsSession: Bool
    private let interval: TimeInterval
    private var timer: Timer?
    private var task: URLSessionDataTask?
    private var localRecognizer: Recognizer?
    private var cancelLocalRequest: (() -> Void)?
    private var requestInFlight = false
    private var active = false
    private(set) var isPaused = false
    private var pausedAt: TimeInterval?
    private var pausePreviewPending = false
    private var pauseSnapshotLoading = false
    private var pauseSnapshot: AudioPreview?
    private var pauseAttempts = 0
    private var generation = UUID()
    private var modelPath = ""
    private var language = "ru"
    private var prompt = ""
    private var usesMemory = false
    private var pcm = Data()
    private var totalBytes: UInt64 = 0
    private var lastByteCount: UInt64 = 0
    private var lastText = ""
    private var stabilizer = LivePreviewStabilizer()
    private var confirmOnSilence = false
    private var lastWarmup = Date.distantPast
    private var retryAfter: TimeInterval = 0
    private var lastPublishedAt: TimeInterval?

    init(directory: URL, serverURL: URL, session: URLSession? = nil,
         interval: TimeInterval = 0.1) {
        self.directory = directory
        self.serverURL = serverURL
        ownsSession = session == nil
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpMaximumConnectionsPerHost = 1
            self.session = URLSession(configuration: configuration)
        }
        self.interval = interval
    }

    func start(modelPath: String, language: String, vocabulary: [String] = [], inMemory: Bool = false,
               recognizer: Recognizer? = nil) {
        stop()
        localRecognizer = recognizer
        self.modelPath = modelPath
        self.language = language.isEmpty ? "ru" : language
        prompt = SpeechVocabulary.prompt(vocabulary)
        usesMemory = inMemory
        pcm.removeAll(keepingCapacity: true)
        totalBytes = 0
        lastByteCount = 0
        lastText = ""
        stabilizer = LivePreviewStabilizer()
        confirmOnSilence = false
        lastWarmup = .distantPast
        retryAfter = 0
        lastPublishedAt = nil
        active = true
        installTimer()
        if recognizer == nil, !serverMatchesModel { ensureServer() }
        recognize()
    }

    private func installTimer() {
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.recognize()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Останавливает периодические запросы, не теряя PCM и подтверждённый текст.
    /// Уже захваченный до остановки микрофона PCM можно дописать на паузе.
    func pause() {
        guard active, !isPaused else { return }
        isPaused = true
        pausedAt = ProcessInfo.processInfo.systemUptime
        cancelRequest()
    }

    /// Фиксирует полный PCM до границы паузы. Заголовок открытого WAV ещё
    /// не финализирован; читаем только его payload, с длиной на момент паузы.
    func finishPausedAudio(audioURL: URL? = nil) {
        guard active, isPaused, !pausePreviewPending else { return }
        pausePreviewPending = true
        pauseAttempts = 0
        retryAfter = 0
        guard let audioURL else { installTimer(); recognize(); return }
        let token = generation
        let byteCount = totalBytes
        guard let size = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size]) as? NSNumber,
              size.uint64Value >= 44 else { failPauseSnapshot(); return }
        let length = (size.uint64Value - 44) / 2 * 2
        pauseSnapshotLoading = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let snapshot: Data? = try? {
                let file = try FileHandle(forReadingFrom: audioURL)
                defer { try? file.close() }
                try file.seek(toOffset: 44)
                guard let pcm = try file.read(upToCount: Int(length)), pcm.count == Int(length) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                return pcm
            }()
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.pauseSnapshotLoading = false
                guard self.isPaused, self.pausePreviewPending else { self.recognize(); return }
                guard let snapshot else { self.failPauseSnapshot(); return }
                self.pauseSnapshot = AudioPreview(byteCount: byteCount, wav: Self.wav(pcm: snapshot),
                                                  isFullRecording: true)
                self.installTimer()
                self.recognize()
            }
        }
    }

    private func failPauseSnapshot() {
        onTiming?(Timing(requestMS: 0, stabilizationMS: 0, updateGapMS: nil, outcome: .failed))
        finishPausePreview()
    }

    func resume() {
        guard active, isPaused else { return }
        if let pausedAt, let lastPublishedAt {
            self.lastPublishedAt = lastPublishedAt + ProcessInfo.processInfo.systemUptime - pausedAt
        }
        pausedAt = nil
        isPaused = false
        pausePreviewPending = false
        pauseSnapshot = nil
        timer?.invalidate()
        installTimer()
        recognize()
    }

    private func cancelRequest() {
        generation = UUID()
        timer?.invalidate()
        timer = nil
        task?.cancel()
        task = nil
        cancelLocalRequest?(); cancelLocalRequest = nil
        requestInFlight = false
    }

    func stop() {
        active = false
        isPaused = false
        pausedAt = nil
        pausePreviewPending = false
        pauseSnapshotLoading = false
        pauseSnapshot = nil
        cancelRequest()
        localRecognizer = nil
        pcm.removeAll(keepingCapacity: true)
    }

    func append(_ data: Data) {
        guard usesMemory, active else { return }
        pcm.append(data)
        totalBytes += UInt64(data.count)
        if pcm.count > 192_000 { pcm.removeFirst(pcm.count - 192_000) }
    }

    private func ensureServer() {
        guard localRecognizer == nil else { return }
        guard Date().timeIntervalSince(lastWarmup) >= 1 else { return }
        lastWarmup = Date()
        onNeedsServer?()
    }

    private var serverMatchesModel: Bool {
        let marker = directory.appendingPathComponent("whisper-server.model")
        guard let identity = try? String(contentsOf: marker, encoding: .utf8) else { return false }
        return identity.components(separatedBy: "|").first == modelPath
    }

    private func recognize() {
        guard timer != nil, !pauseSnapshotLoading, !requestInFlight, ProcessInfo.processInfo.systemUptime >= retryAfter else { return }
        // Не используем сервер с другой или неизвестной моделью.
        guard localRecognizer != nil || serverMatchesModel else {
            ensureServer()
            return
        }
        let settling = isPaused && pausePreviewPending
        let preview: AudioPreview?
        if settling, let pauseSnapshot {
            preview = pauseSnapshot
        } else if usesMemory {
            preview = (settling ? totalBytes > 0 : totalBytes >= max(25_600, lastByteCount + 19_200))
                ? AudioPreview(byteCount: totalBytes, wav: Self.wav(pcm: pcm)) : nil
        } else {
            preview = Self.readPreview(from: directory.appendingPathComponent("rec.pcm"), afterByteCount: lastByteCount, force: settling)
        }
        guard let audio = preview else {
            if settling { finishPausePreview() }
            return
        }
        if settling && !Self.containsSpeech(Data(audio.wav.dropFirst(44))) {
            finishPausePreview()
            return
        }
        let newBytes = min(audio.wav.count - 44, Int(audio.byteCount - lastByteCount))
        let hasNewSpeech = Self.containsSpeech(audio.wav.suffix(newBytes))
        if !hasNewSpeech && !confirmOnSilence && !settling {
            // Новая тишина не повод снова декодировать старые слова: именно
            // такие окна часто порождают повторения и пунктуационные петли.
            lastByteCount = audio.byteCount
            return
        }

        let token = generation
        let requestStartedAt = ProcessInfo.processInfo.systemUptime
        requestInFlight = true
        if settling { pauseAttempts += 1 }
        let completed: (Result<String, Error>) -> Void = { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.generation == token, self.timer != nil else { return }
                self.task = nil; self.cancelLocalRequest = nil; self.requestInFlight = false
                let responseAt = ProcessInfo.processInfo.systemUptime
                let requestMS = Int((responseAt - requestStartedAt) * 1000)
                guard case .success(let recognized) = result else {
                    self.retryAfter = responseAt + 1
                    self.onTiming?(Timing(requestMS: requestMS, stabilizationMS: 0, updateGapMS: nil, outcome: .failed))
                    guard self.generation == token, self.timer != nil else { return }
                    if settling && self.pauseAttempts >= 3 { self.finishPausePreview(); return }
                    self.ensureServer()
                    return
                }
                self.lastByteCount = audio.byteCount
                self.confirmOnSilence = !settling && hasNewSpeech
                let text: String?
                if settling && audio.isFullRecording {
                    text = self.stabilizer.settleRecording(recognized)
                } else {
                    let start = audio.byteCount - UInt64(audio.wav.count - 44)
                    text = self.stabilizer.update(recognized, windowStart: start,
                                                 firstWordOnly: !settling && audio.byteCount < 48_000,
                                                 settled: settling || !hasNewSpeech)
                }
                let stabilizedAt = ProcessInfo.processInfo.systemUptime
                let changed = text != nil && text != self.lastText
                let gap = changed ? self.lastPublishedAt.map { Int((stabilizedAt - $0) * 1000) } : nil
                if changed { self.lastText = text!; self.lastPublishedAt = stabilizedAt }
                self.onTiming?(Timing(requestMS: requestMS,
                                      stabilizationMS: Int((stabilizedAt - responseAt) * 1000),
                                      updateGapMS: gap, outcome: changed ? .published : .unchanged))
                guard self.generation == token, self.timer != nil else { return }
                if changed, let text { self.onUpdate?(text) }
                guard self.generation == token, self.timer != nil else { return }
                if settling { self.finishPausePreview() }
                self.recognize()
            }
        }
        if let localRecognizer {
            cancelLocalRequest = localRecognizer(Data(audio.wav.dropFirst(44)), completed)
            return
        }

        let boundary = "Runvoice-" + UUID().uuidString
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("language", language)
        field("response_format", "json")
        field("translate", "false")
        field("temperature", "0")
        field("temperature_inc", "0")
        field("no_timestamps", "true")
        field("beam_size", settling ? "5" : "1")
        field("best_of", settling ? "5" : "1")
        // 512 кадров энкодера покрывают 10.24 с, с запасом для 6-секундного preview.
        // Полное распознавание после остановки сохраняет исходный аудиоконтекст.
        field("audio_ctx", settling ? "0" : "512")
        field("suppress_nst", "true")
        if !prompt.isEmpty { field("prompt", prompt) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"preview.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        // Завершающая тишина существует только в запросе ASR: она помогает
        // декодеру закрыть последнее слово, но не меняет WAV и активное время.
        let inferenceAudio = settling
            ? Self.wav(pcm: Data(audio.wav.dropFirst(44)) + Data(count: 16_000)) : audio.wav
        body.append(inferenceAudio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: serverURL.appendingPathComponent("inference"))
        request.httpMethod = "POST"
        // Как в итоговом запросе: на медленном CPU не плодим новые задания
        // каждые несколько секунд, пока сервер ещё считает предыдущий фрагмент.
        request.timeoutInterval = 300
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        // Отмена должна закрыть соединение, чтобы abort_callback whisper.cpp
        // остановил preview и освободил модель для итогового запроса.
        request.setValue("close", forHTTPHeaderField: "Connection")
        request.httpBody = body
        let task = session.dataTask(with: request) { data, response, error in
            if let error { completed(.failure(error)) }
            else if (response as? HTTPURLResponse)?.statusCode == 200, let data,
                    let result = try? JSONDecoder().decode(PreviewResult.self, from: data) {
                completed(.success(result.text))
            } else { completed(.failure(URLError(.badServerResponse))) }
        }
        self.task = task
        task.resume()
    }

    private func finishPausePreview() {
        pausePreviewPending = false
        pauseSnapshot = nil
        if isPaused {
            timer?.invalidate()
            timer = nil
        }
    }

    private struct PreviewResult: Decodable { let text: String }

    /// Простой energy gate только для preview, не заменяет VAD итогового ASR.
    static func containsSpeech(_ pcm: Data) -> Bool {
        guard pcm.count >= 2 else { return false }
        var sum: Double = 0
        var peak: Double = 0
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for sample in samples {
                let value = Double(Int16(littleEndian: sample)) / 32768
                sum += value * value
                peak = max(peak, abs(value))
            }
        }
        return sqrt(sum / Double(pcm.count / 2)) >= 0.0015 || peak >= 0.01
    }

    struct AudioPreview {
        let byteCount: UInt64
        let wav: Data
        var isFullRecording = false
    }

    /// Первые 0.8 с и затем каждые 0.6 с нового звука. Окно ограничено 6 секундами.
    static func readPreview(from url: URL, afterByteCount: UInt64 = 0, force: Bool = false) -> AudioPreview? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let length = try? file.seekToEnd() else { return nil }
        let end = length - length % 2 // PCM16: только целые отсчёты.
        guard force ? end > 0 : end >= max(25_600, afterByteCount + 19_200) else { return nil }
        let count = min(end, 6 * 32_000)
        do {
            try file.seek(toOffset: end - count)
            guard let pcm = try file.read(upToCount: Int(count)), pcm.count == Int(count) else { return nil }
            return AudioPreview(byteCount: end, wav: wav(pcm: pcm))
        } catch {
            return nil
        }
    }

    static func wav(pcm: Data) -> Data {
        var result = Data()
        func ascii(_ value: String) { result.append(Data(value.utf8)) }
        func u16(_ value: UInt16) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { result.append(contentsOf: $0) }
        }
        func u32(_ value: UInt32) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { result.append(contentsOf: $0) }
        }
        ascii("RIFF"); u32(UInt32(pcm.count) + 36); ascii("WAVEfmt ")
        u32(16); u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
        ascii("data"); u32(UInt32(pcm.count)); result.append(pcm)
        return result
    }

    deinit {
        timer?.invalidate()
        task?.cancel()
        if ownsSession { session.invalidateAndCancel() }
    }
}
