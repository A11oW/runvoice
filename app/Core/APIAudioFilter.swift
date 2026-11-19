import Foundation

protocol APIAudioFiltering: AnyObject {
    var ready: Bool { get }
    func prepare(_ completion: @escaping (Result<Void, Error>) -> Void)
    func apply(_ pcm: Data, settings: Settings, completion: @escaping (Result<Data, Error>) -> Void)
    func stop()
}

/// Принадлежит только API. Все управляющие методы вызываются на main.
final class APIAudioFilter: APIAudioFiltering {
    private let queue = DispatchQueue(label: "Runvoice.API.VAD")
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var generation = UUID()
    private var initialized = false
    var ready: Bool { initialized && process?.isRunning == true }

    static func retainedRange(pcm: Data, segments: [[Int]], threshold: Double) -> Range<Int>? {
        let samples = pcm.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> [Double] in
            stride(from: 0, to: pcm.count - 1, by: 2).map {
                Double(Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0+1]) << 8)) / 32768
            }
        }
        let limit = pow(10, min(-20, max(-70, threshold)) / 20)
        var accepted: [Range<Int>] = []
        for segment in segments where segment.count == 2 {
            let start = max(0, segment[0]), end = min(samples.count, segment[1])
            guard start < end else { continue }
            var voiced = 0
            for offset in stride(from: start, to: end, by: 320) {
                let upper = min(end, offset + 320)
                let energy = samples[offset..<upper].reduce(0) { $0 + $1 * $1 }
                if sqrt(energy / Double(upper-offset)) >= limit { voiced += upper-offset }
            }
            if voiced >= 1280 { accepted.append(start..<end) }
        }
        guard let start = accepted.map(\.lowerBound).min(), let end = accepted.map(\.upperBound).max() else { return nil }
        return max(0, start-3200)*2..<min(samples.count, end+3200)*2
    }

    func prepare(_ completion: @escaping (Result<Void, Error>) -> Void) {
        if ready, process?.isRunning == true { completion(.success(())); return }
        stop()
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("whisper"),
              FileManager.default.isExecutableFile(atPath: folder.appendingPathComponent("bin/runvoice-vad").path),
              FileManager.default.fileExists(atPath: folder.appendingPathComponent("models/ggml-silero-v5.1.2.bin").path) else {
            completion(.failure(LocalAPIError(503, "Не найден VAD-фильтр API или его модель"))); return
        }
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = folder.appendingPathComponent("bin/runvoice-vad")
        child.arguments = [folder.appendingPathComponent("models/ggml-silero-v5.1.2.bin").path]
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = FileHandle.nullDevice
        process = child; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        let token = generation
        do { try child.run() } catch { stop(); completion(.failure(LocalAPIError(503,"Не удалось запустить VAD API"))); return }
        var completed = false // Только main.
        DispatchQueue.main.asyncAfter(deadline: .now()+5) { [weak self] in
            guard let self, self.generation == token, !completed else { return }
            completed = true; self.stop(); completion(.failure(LocalAPIError(503,"Истекло время запуска VAD API")))
        }
        let reader = stdout.fileHandleForReading
        queue.async { [weak self] in
            let json = Self.readLine(reader)
            DispatchQueue.main.async {
                guard let self, self.generation == token, !completed else { return }
                completed = true
                if json?["ready"] as? Bool == true { self.initialized = true; completion(.success(())) }
                else { self.stop(); completion(.failure(LocalAPIError(503,"Ошибка запуска VAD API"))) }
            }
        }
    }

    func apply(_ pcm: Data, settings: Settings, completion: @escaping (Result<Data, Error>) -> Void) {
        prepare { [weak self] result in
            guard let self else { return }
            guard case .success = result, let writer = self.input, let reader = self.output else {
                completion(.failure(LocalAPIError(503,"VAD API недоступен"))); return
            }
            let token = self.generation
            self.queue.async { [weak self] in
                let filtered: Result<Data, Error>
                do {
                    var count = UInt32(pcm.count).littleEndian
                    var payload = withUnsafeBytes(of: &count) { Data($0) }; payload.append(pcm)
                    try writer.write(contentsOf: payload)
                    guard let segments = Self.readLine(reader)?["segments"] as? [[Int]] else { throw LocalAPIError(503,"Ошибка проверки речи API") }
                    if let range = Self.retainedRange(pcm: pcm, segments: segments, threshold: settings.apiMinimumSpeechDbfs) {
                        filtered = .success(pcm.subdata(in: range))
                    } else {
                        Log.write("api-filter: skipped samples=\(pcm.count/2) threshold_dbfs=\(settings.apiMinimumSpeechDbfs)")
                        filtered = .success(Data())
                    }
                } catch { filtered = .failure(LocalAPIError(503,"Ошибка проверки речи API")) }
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    completion(filtered)
                }
            }
        }
    }

    private static func readLine(_ handle: FileHandle) -> [String: Any]? {
        var data = Data()
        do {
            while data.count < 65536 {
                guard let byte = try handle.read(upToCount: 1), !byte.isEmpty else { return nil }
                if byte[0] == 10 { return try JSONSerialization.jsonObject(with: data) as? [String: Any] }
                data.append(byte)
            }
        } catch { return nil }
        return nil
    }
    func stop() {
        generation = UUID(); initialized = false
        if process?.isRunning == true { process?.terminate() }
        try? input?.close(); try? output?.close()
        input = nil; output = nil; process = nil
    }
    deinit {
        if process?.isRunning == true { process?.terminate() }
        try? input?.close(); try? output?.close()
    }
}
