import Foundation
import FluidAudio
import AVFoundation

/// Отдельный процесс держит Core ML-модель в памяти. Протокол — JSON lines,
/// префикс отделяет сообщения Runvoice от диагностического stdout библиотеки.
enum Wire {
    private static let lock = NSLock()
    static func emit(_ object: [String: any Sendable]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardOutput.write(Data("RUNVOICE_ASR ".utf8) + data + Data([10]))
    }
}

struct Command: Decodable {
    let action: String
    let id: String
    let language: String?
    let pcm: String?
    let vocabulary: [String]?
}

@main
struct RunvoiceASR {
    static func main() async {
        guard CommandLine.arguments.count == 3 else { return }
        let mode = CommandLine.arguments[1]
        let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        do {
            if mode == "download" {
                let model = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
                    languageCode: "auto", chunkMs: 1120, to: directory,
                    progressHandler: { progress in
                        Wire.emit(["event": "progress", "progress": progress.fractionCompleted])
                    })
                // Проверка загрузки до публикации маркера установки.
                let manager = StreamingNemotronMultilingualAsrManager()
                try await manager.loadModels(from: model)
                try model.path.write(to: directory.appendingPathComponent("installed-model"),
                                     atomically: true, encoding: .utf8)
                Wire.emit(["event": "installed"])
                return
            }
            guard mode == "serve" else { return }
            let path = try String(contentsOf: directory.appendingPathComponent("installed-model"), encoding: .utf8)
            // Маркер не позволяет загрузить произвольную папку вне своего хранилища.
            let model = URL(fileURLWithPath: path).standardizedFileURL
            guard model.path.hasPrefix(directory.standardizedFileURL.path + "/") else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            let manager = StreamingNemotronMultilingualAsrManager()
            try await manager.loadModels(from: model)
            let sample = URL(fileURLWithPath: CommandLine.arguments[0])
                .deletingLastPathComponent().appendingPathComponent("warmup.wav")
            if let file = try? AVAudioFile(forReading: sample),
               let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                              frameCapacity: AVAudioFrameCount(file.length)) {
                try file.read(into: buffer)
                if file.processingFormat.sampleRate == 16_000, let samples = buffer.floatChannelData?[0] {
                    _ = try await manager.process(samples: Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength))))
                    _ = try await manager.finish()
                    await manager.reset()
                }
            }
            Wire.emit(["event": "ready"])
            while let line = readLine() {
                guard let data = line.data(using: .utf8),
                      let command = try? JSONDecoder().decode(Command.self, from: data) else { continue }
                do {
                    switch command.action {
                    case "start":
                        await manager.reset()
                        let id = command.id
                        await manager.setPartialCallback { text in
                            Wire.emit(["event": "partial", "id": id, "text": text])
                        }
                        let language = command.language == "ru" ? "ru-RU"
                            : command.language == "en" ? "en-US" : "auto"
                        await manager.setLanguage(language)
                        await manager.setCustomVocabulary((command.vocabulary ?? []).prefix(64)
                            .filter { !$0.isEmpty && $0.count <= 80 }.map { CustomVocabularyTerm(text: $0) })
                    case "audio":
                        guard let encoded = command.pcm, let pcm = Data(base64Encoded: encoded),
                              pcm.count <= 320_000, pcm.count % 2 == 0 else { continue }
                        let samples: [Float] = pcm.withUnsafeBytes { bytes in
                            let words = bytes.bindMemory(to: Int16.self)
                            return words.map { Float(Int16(littleEndian: $0)) / 32768 }
                        }
                        _ = try await manager.process(samples: samples)
                    case "finish":
                        let text = try await manager.finish()
                        Wire.emit(["event": "final", "id": command.id, "text": text])
                    case "cancel": await manager.reset()
                    default: break
                    }
                } catch {
                    Wire.emit(["event": "error", "id": command.id, "message": error.localizedDescription])
                    await manager.reset()
                }
            }
        } catch {
            Wire.emit(["event": "error", "message": error.localizedDescription])
        }
    }
}
