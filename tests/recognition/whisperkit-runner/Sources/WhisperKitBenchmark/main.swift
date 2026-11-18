import Foundation
import CoreML
import WhisperKit

/// Протокол стенда отделён от возможного диагностического stdout SDK.
private enum Wire {
    static func emit(_ value: [String: Any]) {
        do {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            FileHandle.standardOutput.write(Data("RUNVOICE_BENCH ".utf8) + data + Data([10]))
        } catch {
            FileHandle.standardError.write(Data("Ошибка JSON результата: \(error)\n".utf8))
        }
    }
}

/// Модель и токенизатор должны быть подготовлены заранее. Не разрешаем SDK
/// незаметно скачивать токенизатор при ошибке локального экспорта.
private final class OfflineRequests: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        ["http", "https"].contains(request.url?.scheme?.lowercased() ?? "")
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: NSError(domain: "RunvoiceBenchmarkOffline", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Сетевые запросы отключены в процессе бенчмарка"]))
    }
    override func stopLoading() {}
}

private struct Request: Decodable {
    let id: String
    let wav: String
    let language: String
    let prompt: String?
}

private struct BenchmarkError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

private final class FirstHypothesis: @unchecked Sendable {
    private let lock = NSLock()
    private var first: Double?
    private let start: Double
    init(start: Double) { self.start = start }
    func observe(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if first == nil { first = (ProcessInfo.processInfo.systemUptime - start) * 1000 }
    }
    var milliseconds: Double? {
        lock.lock()
        defer { lock.unlock() }
        return first
    }
}

private enum PCMFile {
    /// Только общий вход стенда: PCM16 LE, один канал, 16 кГц. Пересэмплинг
    /// внутри backend исказил бы сравнение с теми же WAV у whisper.cpp.
    static func read(_ path: String) throws -> [Float] {
        let url = URL(fileURLWithPath: path)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0 && size <= 100_000_000 else { throw BenchmarkError("WAV отсутствует, пуст или превышает 100 МБ") }
        let bytes = [UInt8](try Data(contentsOf: url))
        func tag(_ offset: Int) -> String { String(bytes: bytes[offset..<(offset + 4)], encoding: .ascii) ?? "" }
        func u16(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
        func u32(_ offset: Int) -> Int { u16(offset) | u16(offset + 2) << 16 }
        guard bytes.count >= 12, tag(0) == "RIFF", tag(8) == "WAVE" else {
            throw BenchmarkError("Ожидается WAV RIFF/WAVE")
        }
        var format: (Int, Int, Int, Int)?
        var audio: Range<Int>?
        var offset = 12
        while offset + 8 <= bytes.count {
            let name = tag(offset)
            let count = u32(offset + 4)
            let start = offset + 8
            guard count <= bytes.count - start else { throw BenchmarkError("Повреждённый WAV chunk") }
            if name == "fmt " {
                guard count >= 16 else { throw BenchmarkError("Повреждённый формат WAV") }
                format = (u16(start), u16(start + 2), u32(start + 4), u16(start + 14))
            } else if name == "data" {
                audio = start..<(start + count)
            }
            offset = start + count + count % 2
        }
        guard let format, format.0 == 1, format.1 == 1, format.2 == 16_000, format.3 == 16,
              let audio, !audio.isEmpty, audio.count % 2 == 0 else {
            throw BenchmarkError("WAV должен содержать PCM16 LE mono 16000 Hz")
        }
        return stride(from: audio.lowerBound, to: audio.upperBound, by: 2).map {
            Float(Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8)) / 32768
        }
    }
}

@main
struct WhisperKitBenchmark {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard arguments.count == 4, arguments[0] == "--model-dir", arguments[2] == "--tokenizer-dir" else {
                throw BenchmarkError("Использование: WhisperKitBenchmark --model-dir PATH --tokenizer-dir PATH")
            }
            let model = URL(fileURLWithPath: arguments[1], isDirectory: true)
            let tokenizer = URL(fileURLWithPath: arguments[3], isDirectory: true)
            for component in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
                guard ["mlmodelc", "mlpackage"].contains(where: {
                    FileManager.default.fileExists(atPath: model.appendingPathComponent(component + "." + $0).path)
                }) else { throw BenchmarkError("Отсутствует компонент модели \(component)") }
            }
            for name in ["tokenizer.json", "tokenizer_config.json"] {
                let data = try Data(contentsOf: tokenizer.appendingPathComponent(name))
                guard try JSONSerialization.jsonObject(with: data) is [String: Any] else {
                    throw BenchmarkError("Неверный локальный \(name)")
                }
            }
            URLProtocol.registerClass(OfflineRequests.self)
            let loadStarted = ProcessInfo.processInfo.systemUptime
            let compute = ModelComputeOptions(melCompute: .cpuAndGPU,
                audioEncoderCompute: .cpuAndNeuralEngine, textDecoderCompute: .cpuAndNeuralEngine)
            let kit = try await WhisperKit(WhisperKitConfig(modelFolder: model.path,
                tokenizerFolder: tokenizer, computeOptions: compute, verbose: false,
                prewarm: false, load: true, download: false))
            guard kit.tokenizer != nil else { throw BenchmarkError("Токенизатор не загружен") }
            Wire.emit(["event": "ready", "load_ms": (ProcessInfo.processInfo.systemUptime - loadStarted) * 1000,
                "backend": "whisperkit", "sdk_revision": "1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4",
                "compute_units": ["mel": "cpuAndGPU", "encoder": "cpuAndNeuralEngine", "decoder": "cpuAndNeuralEngine"],
                "decoding": ["temperature": 0, "fallback_count": 0, "worker_count": 1,
                    "context_tokens": Constants.maxTokenContext, "timestamps": false, "vad": false,
                    "suppress_blank": true, "no_speech_threshold": 0.6, "logprob_threshold": -1.0,
                    "compression_ratio_threshold": 2.4]])
            while let line = readLine() {
                var identifier: String?
                do {
                    guard line.utf8.count <= 1_000_000, let data = line.data(using: .utf8) else {
                        throw BenchmarkError("Слишком большая или повреждённая JSON-строка")
                    }
                    let request = try JSONDecoder().decode(Request.self, from: data)
                    identifier = request.id
                    guard ["ru", "en", "auto"].contains(request.language) else { throw BenchmarkError("Язык должен быть ru, en или auto") }
                    guard (request.prompt?.count ?? 0) <= 4096 else { throw BenchmarkError("Слишком длинная подсказка") }
                    let started = ProcessInfo.processInfo.systemUptime
                    let audio = try PCMFile.read(request.wav)
                    let tokens = request.prompt.flatMap { $0.isEmpty ? nil : kit.tokenizer?.encode(text: $0) }
                    let options = DecodingOptions(verbose: false, task: .transcribe,
                        language: request.language == "auto" ? nil : request.language,
                        temperature: 0, temperatureIncrementOnFallback: 0, temperatureFallbackCount: 0,
                        usePrefillPrompt: true, detectLanguage: request.language == "auto",
                        skipSpecialTokens: true, withoutTimestamps: true, wordTimestamps: false,
                        windowClipTime: 0, promptTokens: tokens, suppressBlank: true, suppressTokens: [],
                        compressionRatioThreshold: 2.4, logProbThreshold: -1.0,
                        firstTokenLogProbThreshold: nil, noSpeechThreshold: 0.6,
                        concurrentWorkerCount: 1, chunkingStrategy: ChunkingStrategy.none)
                    let clock = FirstHypothesis(start: started)
                    let results = try await kit.transcribe(audioArray: audio, decodeOptions: options) { progress in
                        clock.observe(progress.text)
                        return nil
                    }
                    let duration = (ProcessInfo.processInfo.systemUptime - started) * 1000
                    let text = results.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                    let diagnostics = try results.map { result -> Any in
                        let encoder = JSONEncoder()
                        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
                        return try JSONSerialization.jsonObject(with: encoder.encode(result.timings))
                    }
                    Wire.emit(["event": "result", "id": request.id, "text": text, "milliseconds": duration,
                        "audio_seconds": Double(audio.count) / 16_000,
                        "first_hypothesis_ms": clock.milliseconds.map { $0 as Any } ?? NSNull(),
                        "diagnostics": diagnostics])
                } catch {
                    var event: [String: Any] = ["event": "error", "message": error.localizedDescription]
                    if let identifier { event["id"] = identifier }
                    Wire.emit(event)
                }
            }
        } catch {
            Wire.emit(["event": "error", "message": error.localizedDescription])
            exit(1)
        }
    }
}
