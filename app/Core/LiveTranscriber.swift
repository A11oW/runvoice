import Foundation

/// Предварительное распознавание последних секунд PCM. Итоговую диктовку не меняет.
/// Все методы и onUpdate вызываются в главном потоке; одновременно идёт один запрос.
final class LiveTranscriber {
    var onUpdate: ((String) -> Void)?
    var onNeedsServer: (() -> Void)?

    private let directory: URL
    private let serverURL: URL
    private let session: URLSession
    private let ownsSession: Bool
    private let interval: TimeInterval
    private var timer: Timer?
    private var task: URLSessionDataTask?
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

    init(directory: URL, serverURL: URL, session: URLSession? = nil,
         interval: TimeInterval = 0.25) {
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

    func start(modelPath: String, language: String, vocabulary: [String] = [], inMemory: Bool = false) {
        stop()
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
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.recognize()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        if !serverMatchesModel { ensureServer() }
        recognize()
    }

    func stop() {
        generation = UUID()
        timer?.invalidate()
        timer = nil
        task?.cancel()
        task = nil
        pcm.removeAll(keepingCapacity: true)
    }

    func append(_ data: Data) {
        guard usesMemory, timer != nil else { return }
        pcm.append(data)
        totalBytes += UInt64(data.count)
        if pcm.count > 192_000 { pcm.removeFirst(pcm.count - 192_000) }
    }

    private func ensureServer() {
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
        guard task == nil else { return }
        // Не используем сервер с другой или неизвестной моделью.
        guard serverMatchesModel else {
            ensureServer()
            return
        }
        let preview: AudioPreview?
        if usesMemory {
            preview = totalBytes >= max(25_600, lastByteCount + 19_200)
                ? AudioPreview(byteCount: totalBytes, wav: Self.wav(pcm: pcm)) : nil
        } else {
            preview = Self.readPreview(from: directory.appendingPathComponent("rec.pcm"), afterByteCount: lastByteCount)
        }
        guard let audio = preview else { return }
        let newBytes = min(audio.wav.count - 44, Int(audio.byteCount - lastByteCount))
        let hasNewSpeech = Self.containsSpeech(audio.wav.suffix(newBytes))
        if !hasNewSpeech && !confirmOnSilence {
            // Новая тишина не повод снова декодировать старые слова: именно
            // такие окна часто порождают повторения и пунктуационные петли.
            lastByteCount = audio.byteCount
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
        field("beam_size", "1")
        field("best_of", "1")
        // 512 кадров энкодера покрывают 10.24 с, с запасом для 6-секундного preview.
        // Полное распознавание после остановки сохраняет исходный аудиоконтекст.
        field("audio_ctx", "512")
        field("suppress_nst", "true")
        if !prompt.isEmpty { field("prompt", prompt) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"preview.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(audio.wav)
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
        let token = generation
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, self.generation == token, self.timer != nil else { return }
                self.task = nil
                guard error == nil, (response as? HTTPURLResponse)?.statusCode == 200,
                      let data,
                      let result = try? JSONDecoder().decode(PreviewResult.self, from: data) else {
                    self.ensureServer()
                    return
                }
                self.lastByteCount = audio.byteCount
                self.confirmOnSilence = hasNewSpeech
                let start = audio.byteCount - UInt64(audio.wav.count - 44)
                guard let text = self.stabilizer.update(result.text, windowStart: start,
                                                        firstWordOnly: audio.byteCount < 48_000,
                                                        settled: !hasNewSpeech),
                      text != self.lastText else { return }
                self.lastText = text
                self.onUpdate?(text)
            }
        }
        self.task = task
        task.resume()
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
    }

    /// Первые 0.8 с и затем каждые 0.6 с нового звука. Окно ограничено 6 секундами.
    static func readPreview(from url: URL, afterByteCount: UInt64 = 0) -> AudioPreview? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let length = try? file.seekToEnd() else { return nil }
        let end = length - length % 2 // PCM16: только целые отсчёты.
        guard end >= max(25_600, afterByteCount + 19_200) else { return nil }
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
