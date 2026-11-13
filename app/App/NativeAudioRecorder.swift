import AVFoundation
import AudioToolbox
import CoreAudio
import Synchronization

/// Один входной AUHAL для файла, уровня и ASR. Управление сериализовано на main;
/// ресемплинг и файловый I/O выполняются в processing, вне аудиоколбэка.
final class NativeAudioRecorder {
    struct Recording { let url: URL; let frames: UInt64 }
    enum Failure: LocalizedError {
        case microphone, format, overflow, empty, busy, permission, configuration
        case openDevice(OSStatus)
        var errorDescription: String? {
            switch self {
            case .microphone: return "Выбранный микрофон недоступен"
            case .format: return "Не удалось настроить формат микрофона"
            case .overflow: return "Не удалось обработать аудио вовремя. Повторите запись"
            case .empty: return "Запись слишком короткая или пустая"
            case .busy: return "Микрофон уже используется диктовкой или проверкой"
            case .permission: return "Разрешите Runvoice доступ к микрофону в настройках macOS"
            case .configuration: return "Конфигурация микрофона изменилась. Повторите запись"
            case .openDevice(let code): return "Не удалось открыть микрофон (код \(code))"
            }
        }
    }
    var onAudio: ((Data) -> Void)?
    var onLevel: ((CGFloat) -> Void)?
    var onFailure: ((Error) -> Void)?
    private let processing = DispatchQueue(label: "Runvoice.capture.pcm", qos: .userInitiated)
    // Единственный input и lease на процесс, включая проверку в настройках.
    private static var sharedInput: HALInput?
    private static weak var owner: NativeAudioRecorder?
    private var input: HALInput? { Self.sharedInput }
    private var configurationTimer: Timer?
    private var sink: PCMSink?
    private var generation = UUID()
    private var phase = "idle"
    private var stopCompletions: [(Result<Recording, Error>) -> Void] = []
    private var inputDevice: AudioInputDevice?

    func start(microphone: String, deviceUID: String = "", url: URL,
               completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.main.async { [self] in
            guard phase == "idle", Self.owner == nil else { completion(.failure(Failure.busy)); return }
            // Проверяем устройство до открытия Audio Unit.
            guard let device = AudioInputDevice.resolve(name: microphone, uid: deviceUID) else {
                completion(.failure(Failure.microphone)); return
            }
            phase = "preparing"
            Self.owner = self
            generation = UUID()
            let token = generation
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .denied, .restricted:
                release(); completion(.failure(Failure.permission))
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                    DispatchQueue.main.async {
                        guard let self, self.generation == token, self.phase == "preparing" else { return }
                        if granted { self.open(device: device, url: url, completion: completion) }
                        else { self.release(); completion(.failure(Failure.permission)) }
                    }
                }
            default: open(device: device, url: url, completion: completion)
            }
        }
    }

    private func open(device: AudioInputDevice, url: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            if Self.sharedInput?.deviceID != device.id || Self.sharedInput?.formatMatchesHardware != true {
                Self.sharedInput = nil
                Self.sharedInput = try HALInput(deviceID: device.id)
            }
            let input = Self.sharedInput!
            let format = input.format
            guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                              channels: 1, interleaved: false),
                  let converter = AVAudioConverter(from: format, to: target) else { throw Failure.format }
            converter.downmix = true
            let sink = try PCMSink(url: url, converter: converter, output: target,
                                   onAudio: onAudio, onLevel: onLevel, onFailure: onFailure)
            self.sink = sink
            inputDevice = device
            try input.start(sink: sink, queue: processing)
            phase = "recording"
            let token = generation
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self, self.generation == token else { return }
                self.configurationChanged()
            }
            RunLoop.main.add(timer, forMode: .common)
            configurationTimer = timer
            Log.write("capture: AUHAL started device_id=\(device.id) rate=\(format.sampleRate) channels=\(format.channelCount)")
            completion(.success(()))
        } catch {
            input?.stop()
            sink = nil
            release()
            try? FileManager.default.removeItem(at: url)
            Log.write("capture: start failed \(error.localizedDescription)")
            completion(.failure(error))
        }
    }

    private func configurationChanged() {
        guard phase == "recording", let input, let inputDevice else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive,
                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let present = AudioObjectGetPropertyData(inputDevice.id, &address, 0, nil, &size, &alive) == noErr && alive != 0
        switch Self.configurationAction(devicePresent: present, formatMatches: input.formatMatchesHardware, running: input.isRunning) {
        case .ignore: break
        case .resume:
            do { try input.resume(); Log.write("capture: AUHAL resumed") }
            catch { sink?.fail(Failure.configuration) }
        case .fail: sink?.fail(present ? Failure.configuration : Failure.microphone)
        }
    }

    enum ConfigurationAction { case ignore, resume, fail }
    static func configurationAction(devicePresent: Bool, formatMatches: Bool, running: Bool) -> ConfigurationAction {
        guard devicePresent, formatMatches else { return .fail }
        return running ? .ignore : .resume
    }

    func stop(discard: Bool = false, completion: @escaping (Result<Recording, Error>) -> Void) {
        DispatchQueue.main.async { [self] in
            if phase == "stopping" { stopCompletions.append(completion); return }
            guard phase != "idle" else { completion(.failure(Failure.empty)); return }
            phase = "stopping"
            generation = UUID()
            stopCompletions.append(completion)
            configurationTimer?.invalidate(); configurationTimer = nil
            input?.stop()
            let sink = self.sink
            self.sink = nil
            processing.async {
                let result: Result<Recording, Error>
                do {
                    guard let sink else { throw Failure.empty }
                    let recording = try sink.finish()
                    if discard { try? FileManager.default.removeItem(at: recording.url) }
                    guard discard || recording.frames >= 3200 else { throw Failure.empty }
                    result = .success(recording)
                } catch { result = .failure(error) }
                DispatchQueue.main.async { [self] in
                    release()
                    let callbacks = stopCompletions; stopCompletions.removeAll()
                    callbacks.forEach { $0(result) }
                }
            }
        }
    }

    private func release() {
        phase = "idle"
        inputDevice = nil
        if Self.owner === self { Self.owner = nil }
    }

    static func device(named name: String) -> AudioDeviceID? {
        AudioInputDevice.resolve(name: name)?.id
    }
}

final class CapturePool {
    private let read = Atomic<Int>(0)
    private var write = 0 // Единственный producer — аудиоколбэк.
    private let buffers: [AVAudioPCMBuffer]
    init(format: AVAudioFormat, capacity: AVAudioFrameCount, count: Int) {
        buffers = (0..<count).compactMap { _ in AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) }
    }
    func take() -> AVAudioPCMBuffer? {
        guard !buffers.isEmpty, write - read.load(ordering: .acquiring) < buffers.count else { return nil }
        let buffer = buffers[write % buffers.count]
        write += 1
        return buffer
    }
    func put(_ buffer: AVAudioPCMBuffer) {
        // processing — единственный consumer; освобождает слоты в том же порядке.
        read.wrappingAdd(1, ordering: .releasing)
    }
}

/// Пишет PCM16 непосредственно в WAV, после остановки меняет только заголовок.
final class PCMSink {
    let url: URL
    private let converter: AVAudioConverter
    private let output: AVAudioFormat
    private let file: FileHandle
    private var bytes: UInt64 = 0
    private var failure: Error?
    private let failureLock = NSLock()
    private let onAudio: ((Data) -> Void)?
    private let onLevel: ((CGFloat) -> Void)?
    private let onFailure: ((Error) -> Void)?
    private var lastMeter: UInt64 = 0
    private var level: CGFloat = 0

    init(url: URL, converter: AVAudioConverter, output: AVAudioFormat,
         onAudio: ((Data) -> Void)?, onLevel: ((CGFloat) -> Void)?, onFailure: ((Error) -> Void)?) throws {
        self.url = url; self.converter = converter; self.output = output
        self.onAudio = onAudio; self.onLevel = onLevel; self.onFailure = onFailure
        guard FileManager.default.createFile(atPath: url.path, contents: LiveTranscriber.wav(pcm: Data()),
                                             attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        file = try FileHandle(forWritingTo: url)
        try file.seekToEnd()
    }

    func fail(_ error: Error) {
        failureLock.lock()
        let first = failure == nil
        failure = error
        failureLock.unlock()
        if first { DispatchQueue.main.async { [onFailure] in onFailure?(error) } }
    }

    func consume(_ input: AVAudioPCMBuffer) {
        failureLock.lock(); let failed = failure != nil; failureLock.unlock()
        guard !failed else { return }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 16_000 / input.format.sampleRate)) + 256
        guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, state in
            guard !supplied else { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        if status == .error { fail(error ?? NativeAudioRecorder.Failure.format as NSError); return }
        write(converted)
    }

    private func write(_ converted: AVAudioPCMBuffer) {
        guard converted.frameLength > 0, let samples = converted.floatChannelData?[0] else { return }
        let count = Int(converted.frameLength)
        var pcm = Data(count: count * 2)
        var peak: Float = 0
        pcm.withUnsafeMutableBytes { raw in
            let target = raw.bindMemory(to: Int16.self)
            for i in 0..<count {
                let sample = samples[i].isFinite ? max(-1, min(1, samples[i])) : 0
                peak = max(peak, abs(sample))
                target[i] = Int16(max(-32768, min(32767, Int(sample * 32768)))).littleEndian
            }
        }
        do {
            guard bytes + UInt64(pcm.count) < UInt64(UInt32.max) - 36 else { throw CocoaError(.fileWriteOutOfSpace) }
            try file.write(contentsOf: pcm)
            bytes += UInt64(pcm.count)
            DispatchQueue.main.async { [onAudio] in onAudio?(pcm) }
            if bytes - lastMeter >= 1920 {
                lastMeter = bytes
                let normalized = CGFloat(max(0, min(1, (20 * log10(max(peak, 0.00001)) + 60) / 60)))
                level = max(normalized, level * 0.72)
                let level = level
                DispatchQueue.main.async { [onLevel] in onLevel?(level) }
            }
        } catch { fail(error) }
    }

    func finish() throws -> NativeAudioRecorder.Recording {
        defer { try? file.close() }
        failureLock.lock(); let error = failure; failureLock.unlock()
        if let error { try? FileManager.default.removeItem(at: url); throw error }
        // Дренируем хвост ресемплера до публикации WAV и команды finish в ASR.
        if let tail = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 1024) {
            for _ in 0..<8 {
                var conversionError: NSError?
                let status = converter.convert(to: tail, error: &conversionError) { _, state in
                    state.pointee = .endOfStream; return nil
                }
                if status == .error { throw conversionError ?? CocoaError(.coderInvalidValue) }
                write(tail)
                if status == .endOfStream || tail.frameLength == 0 { break }
            }
        }
        failureLock.lock(); let flushError = failure; failureLock.unlock()
        if let flushError { try? FileManager.default.removeItem(at: url); throw flushError }
        var header = LiveTranscriber.wav(pcm: Data())
        var riff = UInt32(bytes + 36).littleEndian
        var count = UInt32(bytes).littleEndian
        withUnsafeBytes(of: &riff) { header.replaceSubrange(4..<8, with: $0) }
        withUnsafeBytes(of: &count) { header.replaceSubrange(40..<44, with: $0) }
        try file.seek(toOffset: 0)
        try file.write(contentsOf: header)
        return NativeAudioRecorder.Recording(url: url, frames: bytes / 2)
    }
}
