import Foundation
import FluidAudio
import AVFoundation
import CoreML

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
    let request: String?
    let path: String?

    var samples: [Float]? {
        guard let pcm, pcm.utf8.count <= 430_000, let data = Data(base64Encoded: pcm),
              !data.isEmpty, data.count <= 320_000, data.count % 2 == 0 else { return nil }
        return data.withUnsafeBytes { bytes in
            bytes.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32768 }
        }
    }

    static func next() -> Command? {
        while let line = readLine() {
            guard line.utf8.count <= 500_000, let data = line.data(using: .utf8),
                  let command = try? JSONDecoder().decode(Command.self, from: data) else { continue }
            return command
        }
        return nil
    }
}

@main
struct RunvoiceASR {
    static func main() async {
        guard (3...4).contains(CommandLine.arguments.count) else { return }
        let mode = CommandLine.arguments[1]
        let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let modelID = CommandLine.arguments.count == 4 ? CommandLine.arguments[3] : "nemotron"
        do {
            guard ["nemotron", "parakeet-tdt-v3", "parakeet-ultra", "parakeet-redux", "phonon-2.5"].contains(modelID) else {
                throw CocoaError(.featureUnsupported)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if modelID != "nemotron" {
                try await parakeet(mode: mode, directory: directory, modelID: modelID)
                return
            }
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
            let model = try installedDirectory(in: directory)
            let manager = StreamingNemotronMultilingualAsrManager()
            try await manager.loadModels(from: model)
            let sample = warmupURL
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
            var activeID: String?
            var pausedText = ""
            while let command = Command.next() {
                guard command.action == "start" || command.id == activeID else { continue }
                do {
                    switch command.action {
                    case "start":
                        await manager.reset()
                        activeID = command.id
                        pausedText = ""
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
                        guard let samples = command.samples else { throw CocoaError(.coderReadCorrupt) }
                        _ = try await manager.process(samples: samples)
                    case "pause":
                        let tail = try await manager.finish()
                        pausedText = [pausedText, tail].filter { !$0.isEmpty }.joined(separator: " ")
                        Wire.emit(["event": "partial", "id": command.id, "text": pausedText])
                        await manager.reset()
                        let prefix = pausedText
                        let id = command.id
                        await manager.setPartialCallback { text in
                            Wire.emit(["event": "partial", "id": id,
                                       "text": [prefix, text].filter { !$0.isEmpty }.joined(separator: " ")])
                        }
                    case "finish":
                        let tail = try await manager.finish()
                        let text = [pausedText, tail].filter { !$0.isEmpty }.joined(separator: " ")
                        Wire.emit(["event": "final", "id": command.id, "text": text])
                    case "cancel": await manager.reset(); activeID = nil
                    default: break
                    }
                } catch {
                    Wire.emit(["event": "error", "id": command.id, "message": error.localizedDescription])
                    await manager.reset()
                }
            }
        } catch {
            if mode == "download" { try? FileManager.default.removeItem(at: directory.appendingPathComponent("installed-model")) }
            Wire.emit(["event": "error", "message": error.localizedDescription])
        }
    }

    private static var warmupURL: URL {
        URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent().appendingPathComponent("warmup.wav")
    }

    private static func installedDirectory(in directory: URL) throws -> URL {
        let path = try String(contentsOf: directory.appendingPathComponent("installed-model"), encoding: .utf8)
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let model = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        guard model.path.hasPrefix(root.path + "/") else { throw CocoaError(.fileReadInvalidFileName) }
        return model
    }

    private static func parakeet(mode: String, directory: URL, modelID: String) async throws {
        let version: AsrModelVersion
        let repo: Repo
        switch modelID {
        case "parakeet-ultra": version = .ultra; repo = .parakeetUltra
        case "parakeet-redux": version = .redux; repo = .parakeetRedux
        case "phonon-2.5": version = .phonon25; repo = .phonon25
        default: version = .v3; repo = .parakeetV3
        }
        // Redux: GPU с LUT2 падает внутри MPSGraph на части macOS, ANE долго
        // компилируется при первом запуске. CPU — переносимый компактный вариант.
        let encoderUnits: MLComputeUnits? = modelID == "parakeet-redux" ? .cpuOnly : nil
        let models: AsrModels
        let modelDirectory: URL
        if mode == "download" {
            // AsrModels размещает repo рядом с переданным target; передаём именно
            // repo-каталог, чтобы все компоненты остались внутри нашего хранилища.
            modelDirectory = directory.appendingPathComponent(repo.folderName, isDirectory: true)
            models = try await AsrModels.downloadAndLoad(to: modelDirectory, version: version, encoderComputeUnits: encoderUnits,
                progressHandler: { progress in
                    Wire.emit(["event": "progress", "progress": progress.fractionCompleted])
                })
        } else {
            guard mode == "serve" else { return }
            modelDirectory = try installedDirectory(in: directory)
            // Во время диктовки не скачиваем и не восстанавливаем модель по сети.
            models = try AsrModels.loadLocal(from: modelDirectory, version: version, encoderComputeUnits: encoderUnits)
        }
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        if FileManager.default.fileExists(atPath: warmupURL.path) {
            var state = try TdtDecoderState()
            _ = try await manager.transcribe(warmupURL, decoderState: &state)
        }
        if mode == "download" {
            try modelDirectory.path.write(to: directory.appendingPathComponent("installed-model"),
                                          atomically: true, encoding: .utf8)
            Wire.emit(["event": "installed"])
            return
        }
        Wire.emit(["event": "ready"])
        var activeID: String?
        var language: Language?
        while let command = Command.next() {
            if command.action == "start" {
                activeID = command.id
                language = command.language.flatMap(Language.init(rawValue:))
                continue
            }
            guard command.id == activeID else { continue }
            do {
                switch command.action {
                case "preview":
                    guard let samples = command.samples, samples.count <= 96_000,
                          let request = command.request else { throw CocoaError(.coderReadCorrupt) }
                    var state = try TdtDecoderState()
                    let result = try await manager.transcribe(samples, decoderState: &state, language: language)
                    Wire.emit(["event": "preview", "id": command.id, "request": request, "text": result.text])
                case "transcribe":
                    guard let path = command.path, path.hasSuffix(".wav") else { throw CocoaError(.fileReadInvalidFileName) }
                    var state = try TdtDecoderState()
                    let result = try await manager.transcribe(URL(fileURLWithPath: path), decoderState: &state, language: language)
                    Wire.emit(["event": "final", "id": command.id, "text": result.text])
                case "cancel": activeID = nil
                default: break
                }
            } catch {
                var event: [String: any Sendable] = ["event": "error", "id": command.id, "message": error.localizedDescription]
                if let request = command.request { event["request"] = request }
                Wire.emit(event)
            }
        }
    }
}
