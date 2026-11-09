import Foundation

// MARK: - Каталог и поиск моделей Whisper

enum WhisperSize {
    static func text(_ bytes: Int64) -> String {
        let b = Double(bytes)
        if bytes >= 1_000_000_000 { return String(format: "%.2f ГБ", b / 1_000_000_000) }
        if bytes >= 1_000_000 { return String(format: "%.0f МБ", b / 1_000_000) }
        if bytes >= 1_000 { return String(format: "%.0f КБ", b / 1_000) }
        return "\(bytes) Б"
    }
}

/// Модель, которую можно скачать из каталога.
struct WhisperModel: Identifiable, Equatable {
    let id: String
    let fileName: String
    let title: String
    let sizeBytes: Int64
    let sha256: String
    let url: URL
    let note: String
    let recommended: Bool

    var sizeText: String { WhisperSize.text(sizeBytes) }
}

/// Уже лежащая на диске модель.
struct WhisperModelFile: Identifiable, Equatable {
    let path: String
    let fileName: String
    let sizeBytes: Int64
    let isManaged: Bool

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var sizeText: String { WhisperSize.text(sizeBytes) }
    var directory: String { (path as NSString).deletingLastPathComponent }
}

enum WhisperModelCatalog {
    static let models: [WhisperModel] = [
        WhisperModel(
            id: "tiny",
            fileName: "ggml-tiny.bin",
            title: "Tiny",
            sizeBytes: 77_691_713,
            sha256: "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21",
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin")!,
            note: "Самая быстрая, но для русского много ошибок.",
            recommended: false
        ),
        WhisperModel(
            id: "base",
            fileName: "ggml-base.bin",
            title: "Base",
            sizeBytes: 147_951_465,
            sha256: "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe",
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin")!,
            note: "Компромисс для слабых машин, качество среднее.",
            recommended: false
        ),
        WhisperModel(
            id: "small",
            fileName: "ggml-small.bin",
            title: "Small",
            sizeBytes: 487_601_967,
            sha256: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b",
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin")!,
            note: "Заметно быстрее large, качество ниже.",
            recommended: false
        ),
        WhisperModel(
            id: "large-v3-turbo-q5_0",
            fileName: "ggml-large-v3-turbo-q5_0.bin",
            title: "Large v3 Turbo (q5_0)",
            sizeBytes: 574_041_195,
            sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin")!,
            note: "Рекомендуется: лучшее соотношение качества и скорости.",
            recommended: true
        ),
        WhisperModel(
            id: "large-v3-turbo",
            fileName: "ggml-large-v3-turbo.bin",
            title: "Large v3 Turbo",
            sizeBytes: 1_624_555_275,
            sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!,
            note: "Максимальное качество turbo, но больше и медленнее q5_0.",
            recommended: false
        ),
        WhisperModel(
            id: "large-v3",
            fileName: "ggml-large-v3.bin",
            title: "Large v3",
            sizeBytes: 3_095_033_483,
            sha256: "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2",
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin")!,
            note: "Максимальное качество, самый медленный вариант.",
            recommended: false
        ),
    ]
}

enum WhisperModelStore {
    static var modelsDirectory: URL {
        let dir = Paths.support.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                               ofItemAtPath: dir.path)
        return dir
    }

    static var bundledDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("whisper", isDirectory: true)
    }

    static var bundledServer: URL? {
        bundledDirectory?.appendingPathComponent("bin/whisper-server")
    }

    static var bundledCLI: URL? {
        bundledDirectory?.appendingPathComponent("bin/whisper-cli")
    }

    static var bundledVAD: URL? {
        bundledDirectory?.appendingPathComponent("models/ggml-silero-v5.1.2.bin")
    }

    static func managedURL(for model: WhisperModel) -> URL {
        modelsDirectory.appendingPathComponent(model.fileName)
    }

    /// Удаляем недокачанные файлы от прошлых запусков.
    static func cleanupPartialDownloads() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: modelsDirectory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "download" {
            try? FileManager.default.removeItem(at: file)
        }
    }

    static func installedModel(_ model: WhisperModel) -> WhisperModelFile? {
        file(at: managedURL(for: model).path)
    }

    static func isManaged(path: String) -> Bool {
        URL(fileURLWithPath: path).standardized.path
            .hasPrefix(modelsDirectory.standardized.path + "/")
    }

    /// Проверка, что файл похож на модель whisper.cpp (magic `ggml`).
    static func isWhisperModel(at url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber,
              size.int64Value > 1_000_000 else { return false }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let magic = handle.readData(ofLength: 4)
        // GGML_MAGIC 0x67676d6c в little-endian выглядит как "lmgg".
        return magic == Data("lmgg".utf8) || magic == Data("ggml".utf8)
    }

    static func file(at path: String) -> WhisperModelFile? {
        let url = URL(fileURLWithPath: path)
        guard isWhisperModel(at: url),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return nil }
        return WhisperModelFile(path: url.standardized.path,
                                fileName: url.lastPathComponent,
                                sizeBytes: size.int64Value,
                                isManaged: isManaged(path: url.path))
    }

    /// Модели в стандартных папках + дополнительные каталоги пользователя.
    static func foundModels(extraDirectories: [String] = [],
                            excluding: [String] = []) -> [WhisperModelFile] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var directories = [
            modelsDirectory.path,
            home.appendingPathComponent(".local/share/whisper").path,
            home.appendingPathComponent("whisper.cpp/models").path,
        ]
        directories.append(contentsOf: extraDirectories)
        let hidden = Set(excluding.map { URL(fileURLWithPath: $0).standardized.path })

        var byName: [String: WhisperModelFile] = [:]
        for directory in directories {
            let dir = URL(fileURLWithPath: directory)
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) else { continue }
            for url in files where url.pathExtension == "bin" {
                let name = url.lastPathComponent
                guard name.hasPrefix("ggml-"),
                      !name.contains("silero"),
                      !name.contains("vad") else { continue }
                guard let model = file(at: url.path), !hidden.contains(model.path) else { continue }
                // Одинаковые имена: предпочитаем модель, скачанную приложением.
                if let existing = byName[name], !model.isManaged && existing.isManaged { continue }
                byName[name] = model
            }
        }
        return byName.values.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Выбранная пользователем модель или автовыбор, если выбор ещё не сделан.
    static func activeModel(settings: Settings) -> WhisperModelFile? {
        let selected = settings.whisperModelPath
        if !selected.isEmpty {
            // Явно выбранная модель пропала — не подменяем её молча.
            return file(at: selected)
        }
        return autoSelect(from: foundModels(extraDirectories: settings.whisperModelDirs,
                                            excluding: settings.hiddenModelPaths))
    }

    static func autoSelect(from models: [WhisperModelFile]) -> WhisperModelFile? {
        guard !models.isEmpty else { return nil }
        // Порядок предпочтений: turbo q5_0 → turbo → large-v3 → medium → small → base → tiny.
        func score(_ name: String) -> Int {
            if name.contains("large-v3-turbo") {
                return name.contains("q5_0") ? 650 : 600
            }
            if name.contains("large-v3") { return 500 }
            if name.contains("medium") { return 400 }
            if name.contains("small") { return 300 }
            if name.contains("base") { return 200 }
            if name.contains("tiny") { return 100 }
            return 0
        }
        return models.max {
            let a = score($0.fileName), b = score($1.fileName)
            if a != b { return a < b }
            return $0.sizeBytes < $1.sizeBytes
        }
    }
}
