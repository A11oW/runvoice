import Foundation

/// Независимый выбор API; отсутствие настройки сохраняет наследование диктовки.
enum APIRecognitionModel: Codable, Equatable {
    case application
    case whisper(String)
    case fluidAudio(FluidModel)

    struct Choice: Equatable {
        let model: APIRecognitionModel
        let title: String
    }

    static func choices(settings: Settings) -> [Choice] {
        var result = [Choice(model: .application, title: "Как в приложении")]
        var files = WhisperModelStore.foundModels(extraDirectories: settings.whisperModelDirs,
                                                  externalPaths: settings.whisperExternalModelPaths, excluding: settings.hiddenModelPaths)
        if let active = WhisperModelStore.file(at: settings.whisperModelPath),
           !settings.hiddenModelPaths.contains(active.path),
           !files.contains(where: { $0.path == active.path }) {
            files.insert(active, at: 0)
        }
        result += files.map {
            Choice(model: .whisper($0.path), title: "Whisper · " + ($0.catalogModel?.title ?? $0.fileName))
        }
        if FluidModelStore.supported {
            result += FluidModel.allCases.filter { FluidModelStore.installed($0) }.map {
                Choice(model: .fluidAudio($0), title: "FluidAudio · " + $0.title)
            }
        }
        return result
    }

    var title: String {
        switch self {
        case .application: return "Как в приложении"
        case .whisper(let path):
            let file = WhisperModelStore.file(at: path)
            return "Whisper · " + (file?.catalogModel?.title ?? URL(fileURLWithPath: path).lastPathComponent)
        case .fluidAudio(let model): return "FluidAudio · " + model.title
        }
    }

    func availabilityError(settings: Settings) -> String? {
        guard self != .application else { return nil }
        return Self.choices(settings: settings).contains(where: { $0.model == self })
            ? nil : "Модель API недоступна: \(title). Проверьте её в разделе «Распознавание» или выберите другую."
    }
}

extension Settings {
    /// Копия настроек для API, не изменяющая профиль обычной диктовки.
    var apiRecognitionSettings: Settings {
        var result = self
        if !apiUseVocabulary { result.speechVocabulary = [] }
        switch apiRecognitionModel {
        case .application: break
        case .whisper(let path):
            result.recognitionTechnology = .whisper
            result.whisperModelPath = path
        case .fluidAudio(let model):
            result.recognitionTechnology = .fluidAudio
            result.fluidModel = model
        }
        return result
    }
}

extension Settings {
    func copyingAPI(from source: Settings) -> Settings {
        var result = self
        result.apiEnabled = source.apiEnabled
        result.apiPort = source.apiPort
        result.apiImproveText = source.apiImproveText
        result.apiRecognitionModel = source.apiRecognitionModel
        result.apiAudioFilterEnabled = source.apiAudioFilterEnabled
        result.apiMinimumSpeechDbfs = source.apiMinimumSpeechDbfs
        result.apiUseVocabulary = source.apiUseVocabulary
        return result
    }
    func differsOutsideAPI(from other: Settings) -> Bool {
        copyingAPI(from: other) != other
    }
}
