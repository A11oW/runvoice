import Foundation

/// Подаёт контрольный WAV в настоящий LiveTranscriber в темпе речи.
/// Родитель выполняет ASR: stdout RUNVOICE_PREVIEW {event:request,id,wav,language,prompt},
/// stdin {id,text} или {id,error}. Микрофон и пользовательские настройки не используются.
@main
struct PreviewBenchmark {
    static func emit(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        FileHandle.standardOutput.write(Data("RUNVOICE_PREVIEW ".utf8) + data + Data([10]))
    }

    static func main() {
        do { try run() }
        catch {
            emit(["event": "error", "message": error.localizedDescription])
            exit(1)
        }
    }

    private static func run() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        func option(_ name: String, default value: String? = nil) throws -> String {
            if let index = arguments.firstIndex(of: name), index + 1 < arguments.count { return arguments[index + 1] }
            if let value { return value }
            throw BenchmarkError("Не указан параметр \(name)")
        }
        let input = try URL(fileURLWithPath: option("--wav"))
        let language = try option("--language", default: "auto")
        let prompt = try option("--prompt", default: "")
        let pcm = try readPCM(from: input)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("runvoice-preview-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let bridge = ResponseBridge(directory: temporary, language: language, prompt: prompt)
        bridge.startReading()
        let live = LiveTranscriber(directory: temporary, serverURL: URL(string: "http://127.0.0.1:1")!)
        let started = ProcessInfo.processInfo.systemUptime
        var trace: [[String: Any]] = []
        var timings: [LiveTranscriber.Timing] = []
        live.onUpdate = { text in
            trace.append(["ms": Int((ProcessInfo.processInfo.systemUptime - started) * 1000), "text": text])
        }
        live.onTiming = { timings.append($0) }
        live.start(modelPath: "benchmark", language: language, inMemory: true, recognizer: bridge.request)

        // Пакеты тишины дают стабилизатору тот же шанс подтвердить хвост, что и микрофон.
        let audio = pcm + Data(repeating: 0, count: 64_000)
        var offset = 0
        var finishedFeedingAt: TimeInterval?
        let feeder = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            let end = min(audio.count, offset + 1_600)
            if end > offset { live.append(audio.subdata(in: offset..<end)); offset = end }
            if offset == audio.count {
                finishedFeedingAt = ProcessInfo.processInfo.systemUptime
                timer.invalidate()
            }
        }
        defer { feeder.invalidate(); live.stop() }
        emit(["event": "ready", "audio_seconds": Double(pcm.count) / 32_000,
              "window_seconds": 6, "first_audio_seconds": 0.8, "fresh_audio_seconds": 0.6,
              "trailing_silence_seconds": 2])

        var timedOut = false
        while !bridge.closed {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            guard let finished = finishedFeedingAt else { continue }
            let now = ProcessInfo.processInfo.systemUptime
            if now - finished >= 0.1, bridge.pendingCount == 0, now - bridge.lastActivity >= 0.1 { break }
            if now - finished >= 15 { timedOut = true; break }
        }
        let unfinished = bridge.pendingCount
        live.stop()
        let publicationTimes = trace.compactMap { $0["ms"] as? Int }
        let gaps = zip(publicationTimes, publicationTimes.dropFirst()).map { $1 - $0 }.sorted()
        let requests = timings.map(\.requestMS).sorted()
        func percentile(_ values: [Int], _ fraction: Double) -> Any {
            values.isEmpty ? NSNull() : values[Int(Double(values.count - 1) * fraction)] as Any
        }
        let metrics: [String: Any] = [
            "audio_seconds": Double(pcm.count) / 32_000,
            "elapsed_ms": Int((ProcessInfo.processInfo.systemUptime - started) * 1000),
            "first_published_ms": publicationTimes.first as Any? ?? NSNull(),
            "updates": trace.count, "requests": bridge.requestCount,
            "gap_median_ms": percentile(gaps, 0.5), "gap_p95_ms": percentile(gaps, 0.95),
            "gap_max_ms": gaps.last as Any? ?? NSNull(),
            "request_median_ms": percentile(requests, 0.5), "request_p95_ms": percentile(requests, 0.95),
            "failed_requests": timings.filter { $0.outcome == .failed }.count,
            "unfinished_requests": unfinished, "timed_out": timedOut, "bridge_closed": bridge.closed,
        ]
        emit(["event": "result", "metrics": metrics, "trace": trace,
              "text": trace.last?["text"] as? String ?? ""])
    }

    private static func readPCM(from url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        guard data.count >= 12, String(data: data.prefix(4), encoding: .ascii) == "RIFF",
              String(data: data[8..<12], encoding: .ascii) == "WAVE" else { throw BenchmarkError("Некорректный WAV") }
        func integer(_ offset: Int, _ count: Int) -> Int {
            (0..<count).reduce(0) { $0 | (Int(data[offset + $1]) << ($1 * 8)) }
        }
        var cursor = 12
        var validFormat = false
        var audio: Data?
        while cursor + 8 <= data.count {
            let size = integer(cursor + 4, 4)
            let start = cursor + 8
            guard size <= data.count - start else { throw BenchmarkError("Обрезанный WAV") }
            let name = String(data: data[cursor..<(cursor + 4)], encoding: .ascii)
            if name == "fmt ", size >= 16 {
                validFormat = integer(start, 2) == 1 && integer(start + 2, 2) == 1
                    && integer(start + 4, 4) == 16_000 && integer(start + 14, 2) == 16
            } else if name == "data" { audio = data.subdata(in: start..<(start + size)) }
            cursor = start + size + size % 2
        }
        guard validFormat, let audio, !audio.isEmpty, audio.count % 2 == 0 else {
            throw BenchmarkError("Требуется непустой WAV PCM16 mono 16 кГц")
        }
        return audio
    }
}

private struct BenchmarkError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Только чтение stdin выполняется фоново; состояние запросов принадлежит main.
private final class ResponseBridge {
    private struct Pending {
        let wav: URL
        let completion: (Result<String, Error>) -> Void
    }
    private let directory: URL
    private let language: String
    private let prompt: String
    private var pending: [String: Pending] = [:]
    private(set) var requestCount = 0
    private(set) var lastActivity = ProcessInfo.processInfo.systemUptime
    private(set) var closed = false
    var pendingCount: Int { pending.count }

    init(directory: URL, language: String, prompt: String) {
        self.directory = directory; self.language = language; self.prompt = prompt
    }

    func startReading() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while let line = readLine() {
                guard let data = line.data(using: .utf8),
                      let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                DispatchQueue.main.async { self?.receive(response) }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.closed = true
                let abandoned = Array(self.pending.values)
                self.pending.removeAll()
                for item in abandoned {
                    try? FileManager.default.removeItem(at: item.wav)
                    item.completion(.failure(BenchmarkError("Родитель закрыл канал ответов")))
                }
            }
        }
    }

    func request(_ pcm: Data, completion: @escaping (Result<String, Error>) -> Void) -> (() -> Void) {
        requestCount += 1
        let id = String(requestCount)
        let wav = directory.appendingPathComponent("window-\(id).wav")
        do {
            try LiveTranscriber.wav(pcm: pcm).write(to: wav)
            pending[id] = Pending(wav: wav, completion: completion)
            lastActivity = ProcessInfo.processInfo.systemUptime
            PreviewBenchmark.emit(["event": "request", "id": id, "wav": wav.path,
                                   "language": language, "prompt": prompt])
        } catch { completion(.failure(error)) }
        return { [weak self] in
            guard let self, let item = self.pending.removeValue(forKey: id) else { return }
            try? FileManager.default.removeItem(at: item.wav)
        }
    }

    private func receive(_ response: [String: Any]) {
        guard let id = response["id"] as? String, let item = pending.removeValue(forKey: id) else { return }
        try? FileManager.default.removeItem(at: item.wav)
        lastActivity = ProcessInfo.processInfo.systemUptime
        if let error = response["error"] as? String { item.completion(.failure(BenchmarkError(error))) }
        else if let text = response["text"] as? String { item.completion(.success(text)) }
        else { item.completion(.failure(BenchmarkError("Ответ не содержит text или error"))) }
    }
}
