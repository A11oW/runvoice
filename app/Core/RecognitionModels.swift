import Foundation

enum RecognitionTechnology: String, Codable, CaseIterable {
    case whisper
    case fluidAudio = "fluidaudio"

    var title: String {
        switch self {
        case .whisper: return "whisper.cpp · модели Whisper"
        case .fluidAudio: return "FluidAudio · Core ML"
        }
    }

    var isSupported: Bool {
        if self == .whisper { return true }
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }
}

enum FluidModel: String, Codable, CaseIterable {
    case nemotron
    case parakeet = "parakeet-tdt-v3"
    case parakeetUltra = "parakeet-ultra"
    case parakeetRedux = "parakeet-redux"
    case phonon25 = "phonon-2.5"

    var title: String {
        switch self {
        case .nemotron: return "Nemotron Multilingual 0.6B"
        case .parakeet: return "Parakeet TDT v3 · 0.6B"
        case .parakeetUltra: return "Parakeet Ultra · 0.6B"
        case .parakeetRedux: return "Parakeet Redux · 0.6B"
        case .phonon25: return "Phonon-2.5 · 0.6B"
        }
    }

    var estimatedSize: String {
        switch self {
        case .nemotron: return "≈633 МБ"
        case .parakeet: return "≈500 МБ"
        case .parakeetUltra: return "≈630 МБ"
        case .parakeetRedux: return "≈220 МБ"
        case .phonon25: return "≈290 МБ"
        }
    }

    var detail: String {
        switch self {
        case .nemotron: return "Потоковое распознавание · русский и английский"
        case .parakeet: return "25 языков, включая русский и английский · базовый вариант"
        case .parakeetUltra: return "Рекомендуется для сравнения качества · 25 языков, включая русский и английский"
        case .parakeetRedux: return "Компактная · CPU · русский и английский менее точны по тестам разработчика"
        case .phonon25: return "Компактная многоязычная · GPU · экспериментальная"
        }
    }

    var usesWindowedRecognition: Bool { self != .nemotron }
    var finishDeadline: TimeInterval { usesWindowedRecognition ? 300 : 15 }
}
