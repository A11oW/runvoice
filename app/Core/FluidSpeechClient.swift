import Foundation

enum FluidModelStore {
    static func directory(for model: FluidModel) -> URL {
        Paths.support.appendingPathComponent("models/\(model.rawValue)", isDirectory: true)
    }
    static var executable: URL? {
        let url = Bundle.main.resourceURL?.appendingPathComponent("RunvoiceASR")
        return url.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
    }
    static var supported: Bool { RecognitionTechnology.fluidAudio.isSupported }
    static func installed(_ model: FluidModel) -> Bool {
        let directory = directory(for: model).resolvingSymlinksInPath()
        guard let path = try? String(contentsOf: directory.appendingPathComponent("installed-model"), encoding: .utf8) else { return false }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        return (url == directory || url.path.hasPrefix(directory.path + "/"))
            && FileManager.default.fileExists(atPath: url.path)
    }

    static func removeInstalled(_ model: FluidModel) throws {
        let url = directory(for: model)
        guard installed(model),
              try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try FileManager.default.removeItem(at: url)
    }
}

/// Ограниченный JSON-lines транспорт. Ни чтение pipe, ни ожидание Core ML
/// не блокируют главный поток. Сообщения библиотеки без префикса игнорируются.
final class ASRProcess {
    var onEvent: (([String: Any]) -> Void)?
    var onExit: (() -> Void)?
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let writer = DispatchQueue(label: "Runvoice.asr.write", qos: .userInitiated)
    private let executable: URL?
    private let directory: URL
    private var pendingBytes = 0 // Только main.
    private var stopped = false

    init(executable: URL? = FluidModelStore.executable, directory: URL = FluidModelStore.directory(for: .nemotron)) {
        self.executable = executable
        self.directory = directory
    }

    func start(mode: String, model: FluidModel = .nemotron) throws {
        guard let executable else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        signal(SIGPIPE, SIG_IGN)
        process.executableURL = executable
        process.arguments = [mode, directory.path, model.rawValue]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let handle = output.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var buffer = Data()
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                buffer.append(data)
                // Ограничение на случай повреждённого/неожиданного stdout.
                if buffer.count > 2_000_000 { buffer.removeAll() }
                while let newline = buffer.firstIndex(of: 10) {
                    let line = buffer.subdata(in: 0..<newline)
                    buffer.removeSubrange(0...newline)
                    let prefix = Data("RUNVOICE_ASR ".utf8)
                    guard line.starts(with: prefix),
                          let event = try? JSONSerialization.jsonObject(with: line.dropFirst(prefix.count)) as? [String: Any] else { continue }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, !self.stopped else { return }
                        self.onEvent?(event)
                    }
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopped else { return }
                self.onExit?()
            }
        }
    }

    @discardableResult
    func send(_ object: [String: Any]) -> Bool {
        guard !stopped, process.isRunning,
              var data = try? JSONSerialization.data(withJSONObject: object) else { return false }
        data.append(10)
        guard pendingBytes + data.count <= 8_000_000 else { return false }
        pendingBytes += data.count
        let count = data.count
        writer.async { [weak self, input] in
            do { try input.fileHandleForWriting.write(contentsOf: data) }
            catch { DispatchQueue.main.async { [weak self] in self?.onExit?() } }
            DispatchQueue.main.async { [weak self] in self?.pendingBytes -= count }
        }
        return true
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        onEvent = nil; onExit = nil
        if process.isRunning { process.terminate() }
        // После SIGTERM чтение/запись завершаются, не ждём их на main.
        writer.async { [input] in try? input.fileHandleForWriting.close() }
    }
    deinit { if process.isRunning { process.terminate() } }
}

final class FluidSpeechClient {
    var onPartial: ((String) -> Void)?
    var onFailure: (() -> Void)?
    private var worker: ASRProcess?
    private var id = UUID().uuidString
    private var finishing: ((String?) -> Void)?
    private var finishTimeout: DispatchWorkItem?
    private(set) var healthy = false
    private(set) var ready = false
    private var model: FluidModel = .nemotron
    private let makeWorker: (FluidModel) -> ASRProcess
    private let isInstalled: (FluidModel) -> Bool
    private let finishDeadline: TimeInterval?
    private var previewID: String?
    private var previewCompletion: ((Result<String, Error>) -> Void)?
    private var previewTimeout: DispatchWorkItem?

    init(makeWorker: @escaping (FluidModel) -> ASRProcess = { ASRProcess(directory: FluidModelStore.directory(for: $0)) },
         isInstalled: @escaping (FluidModel) -> Bool = { FluidModelStore.supported && FluidModelStore.installed($0) },
         finishDeadline: TimeInterval? = nil) {
        self.makeWorker = makeWorker
        self.isInstalled = isInstalled
        self.finishDeadline = finishDeadline
    }

    func warmUp(model: FluidModel = .nemotron) {
        if self.model != model { unload(); self.model = model }
        guard isInstalled(model), worker == nil else { return }
        let worker = makeWorker(model)
        worker.onEvent = { [weak self] event in self?.receive(event) }
        worker.onExit = { [weak self] in self?.fail() }
        self.worker = worker
        do { try worker.start(mode: "serve", model: model); healthy = true }
        catch { fail() }
    }

    func start(model: FluidModel = .nemotron, language: String, vocabulary: [String] = []) {
        cancel()
        warmUp(model: model)
        id = UUID().uuidString
        guard worker?.send(["action": "start", "id": id, "language": language,
                            "vocabulary": SpeechVocabulary.normalize(vocabulary)]) == true else { fail(); return }
    }

    func append(_ pcm: Data) {
        guard healthy, model == .nemotron else { return }
        guard worker?.send(["action": "audio", "id": id, "pcm": pcm.base64EncodedString()]) == true else { fail(); return }
    }

    /// Только один снимок Parakeet одновременно. Отмена отцепляет callback;
    /// текущая Core ML prediction может закончиться, её ответ уже не публикуется.
    func preview(_ pcm: Data, completion: @escaping (Result<String, Error>) -> Void) -> () -> Void {
        guard healthy, model.usesWindowedRecognition, previewID == nil else {
            completion(.failure(CocoaError(.featureUnsupported)))
            return {}
        }
        let request = UUID().uuidString
        previewID = request
        previewCompletion = completion
        guard worker?.send(["action": "preview", "id": id, "request": request,
                            "pcm": pcm.base64EncodedString()]) == true else {
            fail()
            return {}
        }
        let timeout = DispatchWorkItem { [weak self] in self?.fail() }
        previewTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
        return { [weak self] in
            guard self?.previewID == request else { return }
            self?.discardPreview()
        }
    }

    /// Дренирует текущий отрезок Nemotron; worker сохраняет текст сессии.
    func finishPausedAudio() {
        guard healthy, model == .nemotron else { return }
        guard worker?.send(["action": "pause", "id": id]) == true else { fail(); return }
    }

    func finish(audio: URL? = nil, completion: @escaping (String?) -> Void) {
        guard healthy else { completion(nil); return }
        discardPreview()
        finishing = completion
        var command: [String: Any] = ["action": model.usesWindowedRecognition ? "transcribe" : "finish", "id": id]
        if model.usesWindowedRecognition {
            guard let audio else { fail(); return }
            command["path"] = audio.path
        }
        guard worker?.send(command) == true else { fail(); return }
        // Сбой Core ML не должен бесконечно задерживать финальное распознавание.
        let timeout = DispatchWorkItem { [weak self] in self?.fail() }
        finishTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + (finishDeadline ?? model.finishDeadline), execute: timeout)
    }

    func cancel() {
        discardPreview()
        finishTimeout?.cancel(); finishTimeout = nil
        finishing = nil
        _ = worker?.send(["action": "cancel", "id": id])
        id = UUID().uuidString
    }

    func unload() { cancel(); worker?.stop(); worker = nil; healthy = false; ready = false }

    private func receive(_ event: [String: Any]) {
        let kind = event["event"] as? String
        if kind == "ready" { ready = true; return }
        if let request = event["request"] as? String {
            guard event["id"] as? String == id, request == previewID else { return }
            let callback = previewCompletion
            discardPreview()
            if kind == "preview", let text = event["text"] as? String { callback?(.success(text)) }
            else { callback?(.failure(CocoaError(.coderReadCorrupt))) }
            return
        }
        if kind == "error", event["id"] == nil || event["id"] as? String == id { fail(); return }
        guard event["id"] as? String == id else { return }
        if kind == "partial", let text = event["text"] as? String { onPartial?(text) }
        if kind == "final" {
            finishTimeout?.cancel(); finishTimeout = nil
            let callback = finishing; finishing = nil
            let text = (event["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            callback?(text?.isEmpty == false ? text : nil)
        }
    }

    private func fail() {
        let wasHealthy = healthy
        healthy = false
        ready = false
        worker?.stop(); worker = nil
        finishTimeout?.cancel(); finishTimeout = nil
        let callback = finishing; finishing = nil
        let previewCallback = previewCompletion
        discardPreview()
        if wasHealthy { onFailure?() }
        previewCallback?(.failure(CocoaError(.executableRuntimeMismatch)))
        callback?(nil)
    }

    private func discardPreview() {
        previewTimeout?.cancel(); previewTimeout = nil
        previewID = nil; previewCompletion = nil
    }
}
