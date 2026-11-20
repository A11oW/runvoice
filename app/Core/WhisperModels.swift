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
    var experimental = false

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
    var catalogModel: WhisperModel? {
        WhisperModelCatalog.models.first { $0.fileName == fileName || $0.url.lastPathComponent == fileName }
    }
}

enum WhisperModelCatalog {
    static let models: [WhisperModel] = [
        model("tiny", title: "Tiny", size: 77691713,
              sha256: "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21",
              note: "Для быстрой пробы; точность ниже старших моделей."),
        model("tiny-q5_1", title: "Tiny (q5_1)", size: 32152673,
              sha256: "818710568da3ca15689e31a743197b520007872ff9576237bda97bd1b469c3d7",
              note: "Минимальный размер; для слабых машин и коротких простых фраз."),
        model("base", title: "Base", size: 147951465,
              sha256: "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe",
              note: "Невысокие требования к памяти, ограниченная точность."),
        model("base-q5_1", title: "Base (q5_1)", size: 59707625,
              sha256: "422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898",
              note: "Компактный Base; русский и английский."),
        model("small", title: "Small", size: 487601967,
              sha256: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b",
              note: "Средний вариант для CPU; русский и английский."),
        model("small-q5_1", title: "Small (q5_1)", size: 190085487,
              sha256: "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb",
              note: "Компактная модель для Intel и экономии памяти."),
        model("medium", title: "Medium", size: 1533763059,
              sha256: "6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208",
              note: "Для сравнения качества с Small; больше памяти и времени."),
        model("medium-q5_0", title: "Medium (q5_0)", size: 539212467,
              sha256: "19fea4b380c3a618ec4723c3eef2eb785ffba0d0538cf43f8f235e7b3b34220f",
              note: "Medium с уменьшенным размером; подходит для сравнения на Intel."),
        model("large-v2", title: "Large v2", size: 3094623691,
              sha256: "9a423fe4d40c82774b6af34115b8b935f34152246eb19e80e376071d3f999487",
              note: "Альтернатива Large v3 для сравнения на своей речи; высокая нагрузка."),
        model("large-v2-q5_0", title: "Large v2 (q5_0)", size: 1080732091,
              sha256: "3a214837221e4530dbc1fe8d734f302af393eb30bd0ed046042ebf4baf70f6f2",
              note: "Компактный Large v2; медленнее Turbo."),
        model("large-v3", title: "Large v3", size: 3095033483,
              sha256: "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2",
              note: "Приоритет качества; больше памяти и времени, чем у Turbo."),
        model("large-v3-q5_0", title: "Large v3 (q5_0)", size: 1081140203,
              sha256: "d75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1",
              note: "Полная архитектура Large v3 с меньшим размером; медленнее Turbo."),
        model("large-v3-turbo", title: "Large v3 Turbo", size: 1624555275,
              sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
              note: "Полный размер Turbo; для сравнения с квантованными вариантами."),
        model("large-v3-turbo-q5_0", title: "Large v3 Turbo (q5_0)", size: 574041195,
              sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
              note: "Рекомендуется для повседневной диктовки: баланс скорости и размера.", recommended: true),
        model("large-v3-turbo-q8_0", title: "Large v3 Turbo (q8_0)", size: 874188075,
              sha256: "317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1",
              note: "Менее сильное сжатие, чем Q5; промежуточный вариант по размеру."),
        codeSwitch("q8_0", size: 874188075,
                   sha256: "c56311968f8bf83d5bf02bd6509d8a663380521236fb45bd498a4e60cc8effea"),
        codeSwitch("f16", size: 1624555275,
                   sha256: "bbfaf9fcc9d0bfe93188abe7ab1a614ed0b00f735efc8a8fdb8f3562fc781e72"),
    ]

    private static func model(_ id: String, title: String, size: Int64, sha256: String,
                              note: String, recommended: Bool = false) -> WhisperModel {
        let file = "ggml-\(id).bin"
        return WhisperModel(id: id, fileName: file, title: title, sizeBytes: size, sha256: sha256,
                            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(file)")!,
                            note: note, recommended: recommended)
    }

    private static func codeSwitch(_ variant: String, size: Int64, sha256: String) -> WhisperModel {
        let id = "large-v3-turbo-russian-codeswitch-\(variant)"
        let asset = "coriollon-whisper-large-v3-turbo-russian-codeswitch-\(variant).bin"
        return WhisperModel(id: id, fileName: "ggml-\(id).bin",
                            title: "Large v3 Turbo RU/EN (\(variant == "f16" ? "FP16" : "q8_0"))",
                            sizeBytes: size, sha256: sha256,
                            url: URL(string: "https://huggingface.co/landco11/coriollon-whisper-large-v3-turbo-russian-codeswitch-f8-f16/resolve/7e4b22af50a2bfdc5189f65b797ffe330396c616/\(asset)")!,
                            note: "Экспериментальная донастройка coriollon для русского с английскими IT-терминами. Сравните с обычным Turbo: качество русского и английского может отличаться.",
                            recommended: false, experimental: true)
    }
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

    static func isDiscoverableModelName(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return url.pathExtension == "bin" && name.hasPrefix("ggml-") && !name.contains("silero") && !name.contains("vad")
    }

    /// Модели в стандартных папках + дополнительные каталоги пользователя.
    static func foundModels(extraDirectories: [String] = [],
                            externalPaths: [String] = [], excluding: [String] = []) -> [WhisperModelFile] {
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
            for url in files where isDiscoverableModelName(url) {
                let name = url.lastPathComponent
                guard let model = file(at: url.path), !hidden.contains(model.path) else { continue }
                // Одинаковые имена: предпочитаем модель, скачанную приложением.
                if let existing = byName[name], !model.isManaged && existing.isManaged { continue }
                byName[name] = model
            }
        }
        var byPath = Dictionary(uniqueKeysWithValues: byName.values.map { ($0.path, $0) })
        for path in externalPaths {
            guard let model = file(at: path), !hidden.contains(model.path) else { continue }
            byPath[model.path] = model
        }
        return byPath.values.sorted { $0.sizeBytes == $1.sizeBytes ? $0.path < $1.path : $0.sizeBytes > $1.sizeBytes }
    }

    /// Выбранная пользователем модель или автовыбор, если выбор ещё не сделан.
    static func activeModel(settings: Settings) -> WhisperModelFile? {
        let selected = settings.whisperModelPath
        if !selected.isEmpty {
            // Явно выбранная модель пропала — не подменяем её молча.
            return file(at: selected)
        }
        return autoSelect(from: foundModels(extraDirectories: settings.whisperModelDirs,
                                            externalPaths: settings.whisperExternalModelPaths, excluding: settings.hiddenModelPaths))
    }

    static func autoSelect(from models: [WhisperModelFile]) -> WhisperModelFile? {
        let candidates = models.filter { $0.catalogModel?.experimental != true }
        guard !candidates.isEmpty else { return nil }
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
        return candidates.max {
            let a = score($0.fileName), b = score($1.fileName)
            if a != b { return a < b }
            return $0.sizeBytes < $1.sizeBytes
        }
    }
}
