import Foundation

/// Локальная запись для настройки индикации. Не подключает ASR, VAD, AI или историю.
final class AudioSampleRecorder {
    enum State { case idle, preparing, recording, saving }
    private(set) var state = State.idle { didSet { onChange?() } }
    private(set) var message = "Запишите 15–30 секунд обычным голосом. Автостоп через минуту."
    private(set) var directory: URL?
    var onChange: (() -> Void)?
    var onSpectrum: (([CGFloat]) -> Void)?
    private(set) var elapsedSeconds = 0
    private let spectrum = AudioSpectrumAnalyzer()
    private let recorder: DictationAudioRecording
    private var timer: Timer?
    private var started = Date()
    private var url: URL?
    private var microphone = ""

    init(recorder: DictationAudioRecording = NativeAudioRecorder()) { self.recorder = recorder }

    static var sourceProject: URL? {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return FileManager.default.fileExists(atPath: root.appendingPathComponent("app/Info.plist").path) ? root : nil
    }

    static func prepareDirectory(in project: URL) throws -> URL {
        guard FileManager.default.fileExists(atPath: project.appendingPathComponent(".git").path),
              FileManager.default.fileExists(atPath: project.appendingPathComponent("app/Info.plist").path) else {
            throw SampleError.project
        }
        let ignore = project.appendingPathComponent(".gitignore")
        var text = try String(contentsOf: ignore, encoding: .utf8)
        if !text.components(separatedBy: .newlines).contains("/local-audio-samples/") {
            if !text.hasSuffix("\n") { text += "\n" }
            text += "\n# Локальные аудиосэмплы голоса\n/local-audio-samples/\n"
            try text.write(to: ignore, atomically: true, encoding: .utf8)
        }
        let folder = project.appendingPathComponent("local-audio-samples", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        return folder
    }

    /// Произвольная локальная папка. Внутри Git исключается только выбранный
    /// подкаталог; корень репозитория и служебная .git не допускаются.
    static func prepareSampleDirectory(at chosen: URL) throws -> URL {
        let folder = chosen.standardizedFileURL.resolvingSymlinksInPath()
        guard !folder.pathComponents.contains(".git"), !folder.path.contains("\n"), !folder.path.contains("\r") else { throw SampleError.directory }
        var ancestor = folder
        for _ in folder.pathComponents {
            if FileManager.default.fileExists(atPath: ancestor.appendingPathComponent(".git").path) {
                guard ancestor.path != folder.path else { throw SampleError.directory }
                let relative = String(folder.path.dropFirst(ancestor.path.count + 1))
                let escaped = relative.reduce(into: "") { result, character in
                    if "\\ *?[]!#".contains(character) { result.append("\\") }
                    result.append(character)
                }
                let rule = "/" + escaped + "/"
                let ignore = ancestor.appendingPathComponent(".gitignore")
                var text = FileManager.default.fileExists(atPath: ignore.path)
                    ? try String(contentsOf: ignore, encoding: .utf8) : ""
                if !text.components(separatedBy: .newlines).contains(rule) {
                    if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
                    text += "\n# Локальные аудиосэмплы голоса\n" + rule + "\n"
                    try text.write(to: ignore, atomically: true, encoding: .utf8)
                }
                break
            }
            let parentPath = (ancestor.path as NSString).deletingLastPathComponent
            if parentPath.isEmpty || parentPath == ancestor.path { break }
            ancestor = URL(fileURLWithPath: parentPath, isDirectory: true)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        return folder
    }

    func start(project: URL, microphone: String, deviceUID: String) {
        guard state == .idle, !UpdateCoordinator.shared.isInstalling else { return }
        do { start(directory: try Self.prepareDirectory(in: project), microphone: microphone, deviceUID: deviceUID) }
        catch { message = error.localizedDescription; onChange?() }
    }

    func start(directory selected: URL, microphone: String, deviceUID: String) {
        guard state == .idle, !UpdateCoordinator.shared.isInstalling else { return }
        let status = (try? String(contentsOf: Paths.status, encoding: .utf8)).flatMap(DictationState.init(raw:))
        guard !["preparing", "recording", "paused", "transcribing", "fixing"].contains(status?.key ?? "") else {
            message = "Сначала завершите диктовку."; onChange?(); return
        }
        do { directory = try Self.prepareSampleDirectory(at: selected) }
        catch { message = error.localizedDescription; onChange?(); return }
        let date = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let file = directory!.appendingPathComponent("sample-\(date)-\(UUID().uuidString.prefix(8)).wav")
        url = file
        self.microphone = microphone
        elapsedSeconds = 0
        spectrum.reset()
        recorder.onAudio = { [weak self] pcm in
            guard let self, self.state == .recording, let levels = self.spectrum.consume(pcm) else { return }
            self.onSpectrum?(levels)
        }
        message = "Готовлю микрофон…"
        state = .preparing
        recorder.onFailure = { [weak self] error in self?.fail(error) }
        recorder.start(microphone: microphone, deviceUID: deviceUID, url: file) { [weak self] result in
            guard let self, self.state == .preparing else { return }
            switch result {
            case .failure(let error): self.finishWithError(error)
            case .success:
                self.started = Date()
                self.message = "Идёт запись: 0 с / 60 с"
                self.state = .recording
                let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    let seconds = Int(Date().timeIntervalSince(self.started))
                    self.elapsedSeconds = min(60, seconds)
                    if seconds >= 60 { self.stop(); return }
                    self.message = "Идёт запись: \(seconds) с / 60 с"
                    self.onChange?()
                }
                self.timer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        }
    }

    func stop() {
        guard state == .recording || state == .preparing else { return }
        timer?.invalidate(); timer = nil
        elapsedSeconds = state == .recording ? min(60, Int(Date().timeIntervalSince(started))) : 0
        onSpectrum?([CGFloat](repeating: 0, count: AudioSpectrumAnalyzer.bandCount))
        message = "Сохраняю сэмпл…"; state = .saving
        recorder.stop(discard: false) { [self] result in
            recorder.onFailure = nil
            recorder.onAudio = nil
            switch result {
            case .failure(let error): finishWithError(error)
            case .success(let recording):
                let microphone = self.microphone
                DispatchQueue.global(qos: .utility).async {
                    let result = Result { try Self.writeMetrics(for: recording.url, microphone: microphone) }
                    DispatchQueue.main.async {
                        switch result {
                        case .success:
                            self.message = "Сохранён \(recording.url.lastPathComponent) и JSON с уровнями."
                        case .failure:
                            self.message = "WAV сохранён; не удалось сохранить JSON с уровнями."
                        }
                        self.url = nil
                        self.state = .idle
                    }
                }
            }
        }
    }

    private func fail(_ error: Error) {
        guard state == .recording || state == .preparing else { return }
        timer?.invalidate(); timer = nil
        state = .saving
        recorder.stop(discard: true) { [self] _ in finishWithError(error) }
    }

    private func finishWithError(_ error: Error) {
        timer?.invalidate(); timer = nil
        recorder.onFailure = nil
        recorder.onAudio = nil
        onSpectrum?([CGFloat](repeating: 0, count: AudioSpectrumAnalyzer.bandCount))
        if let url { try? FileManager.default.removeItem(at: url) }
        url = nil
        message = error.localizedDescription
        state = .idle
    }

    static func writeMetrics(for audio: URL, microphone: String) throws {
        let wav = try Data(contentsOf: audio)
        guard wav.count >= 44 else { throw NativeAudioRecorder.Failure.empty }
        let pcm = Data(wav.dropFirst(44))
        var frames: [[String: Double]] = []
        var rmsValues: [Double] = []
        var total: Double = 0, peak: Double = 0
        var clipped = 0
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for start in stride(from: 0, to: samples.count, by: 1024) {
                let end = min(samples.count, start + 1024)
                var energy: Double = 0, framePeak: Double = 0
                for index in start..<end {
                    let value = abs(Double(Int16(littleEndian: samples[index])) / 32768)
                    energy += value * value
                    framePeak = max(framePeak, value)
                    if value >= 0.999 { clipped += 1 }
                }
                let rms = sqrt(energy / Double(end - start))
                total += energy; peak = max(peak, framePeak); rmsValues.append(rms)
                frames.append(["time_seconds": Double(start) / 16000,
                               "rms_dbfs": db(rms), "peak_dbfs": db(framePeak)])
            }
        }
        let ordered = rmsValues.sorted()
        func percentile(_ fraction: Double) -> Double {
            ordered.isEmpty ? -120 : db(ordered[Int(Double(ordered.count - 1) * fraction)])
        }
        let report: [String: Any] = [
            "format": "PCM16", "sample_rate_hz": 16000, "channels": 1,
            "audio_file": audio.lastPathComponent, "microphone": microphone,
            "duration_seconds": Double(pcm.count) / 32000,
            "rms_dbfs": db(sqrt(total / Double(max(1, pcm.count / 2)))),
            "peak_dbfs": db(peak), "clipped_samples": clipped,
            "frame_seconds": 0.064, "frame_rms_p10_dbfs": percentile(0.10),
            "frame_rms_p50_dbfs": percentile(0.50), "frame_rms_p90_dbfs": percentile(0.90),
            "frame_rms_p95_dbfs": percentile(0.95), "frames": frames,
            "processing": "none; mono 16 kHz conversion only"
        ]
        let json = audio.deletingPathExtension().appendingPathExtension("json")
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: json, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: json.path)
    }

    private static func db(_ value: Double) -> Double { 20 * log10(max(0.000001, value)) }
    enum SampleError: LocalizedError {
        case project, directory
        var errorDescription: String? {
            switch self {
            case .project: return "Выберите папку исходников Runvoice (с .git и app/Info.plist)."
            case .directory: return "Выберите отдельную папку для сэмплов, не корень Git-проекта и не .git."
            }
        }
    }
}
