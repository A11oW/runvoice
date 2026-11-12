import Foundation

/// Что показывать в HUD для конкретного состояния.
struct HUDContent {
    enum Accent {
        case neutral, success, info, warning
    }

    let text: String
    let busy: Bool
    let icon: String
    let hudIcon: String
    let accent: Accent
    let autoHideAfter: TimeInterval?
    var showLevel = false
    var showStop = false
    var showSpinner = false
    var transcript = ""
    var delivery: HUDDelivery? = nil

    var displayText: String {
        guard let delivery else { return text }
        return "\(delivery.application?.name ?? text) · \(delivery.words)"
    }

    static func completed(text: String, application: HUDApplication?, pasted: Bool = true) -> HUDContent {
        var content = HUDContent(text: pasted ? "Готово" : "Скопировано", busy: false,
                                 icon: pasted ? "checkmark" : "info.circle",
                                 hudIcon: pasted ? "checkmark.circle" : "info.circle",
                                 accent: pasted ? .success : .info, autoHideAfter: pasted ? 1 : 1.8)
        content.delivery = HUDDelivery(text: text, application: pasted ? application : nil)
        return content
    }
}

enum StatusItemSymbol {
    static let idle = "waveform"
    static let listening = "mic"
    static let processing = "ellipsis"
}

/// Состояние диктовки, которое приложение читает из файла status.
enum DictationState: Equatable {
    case preparing
    case recording
    case transcribing
    case fixing(message: String)
    case done(message: String)
    case info(message: String)
    case error(message: String)
    case idle

    init?(raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let parts = text.split(separator: "|", maxSplits: 1).map(String.init)
        let name = parts[0]
        let message = parts.count > 1 ? parts[1] : ""

        switch name {
        case "preparing": self = .preparing
        case "recording": self = .recording
        case "transcribing": self = .transcribing
        case "fixing": self = .fixing(message: message)
        case "done": self = .done(message: message)
        case "info": self = .info(message: message)
        case "error": self = .error(message: message)
        case "idle", "quit": self = .idle
        default: return nil
        }
    }

    /// Ключ для сравнения с предыдущим состоянием и для лога.
    var key: String {
        switch self {
        case .preparing: return "preparing"
        case .recording: return "recording"
        case .transcribing: return "transcribing"
        case .fixing: return "fixing"
        case .done: return "done"
        case .info: return "info"
        case .error: return "error"
        case .idle: return "idle"
        }
    }

    var message: String {
        switch self {
        case .fixing(let message), .done(let message), .info(let message), .error(let message): return message
        default: return ""
        }
    }

    var statusItemSymbol: String {
        switch self {
        case .recording: return StatusItemSymbol.listening
        case .transcribing, .fixing: return StatusItemSymbol.processing
        default: return StatusItemSymbol.idle
        }
    }

    /// nil — HUD нужно скрыть.
    var hud: HUDContent? {
        switch self {
        case .preparing:
            return HUDContent(text: "Готовлю микрофон…", busy: true, icon: "mic",
                              hudIcon: "mic", accent: .neutral, autoHideAfter: nil)
        case .recording:
            return HUDContent(text: "Слушаю…", busy: true, icon: "mic",
                              hudIcon: "mic", accent: .neutral, autoHideAfter: nil,
                              showLevel: true, showStop: true)
        case .transcribing:
            return HUDContent(text: "Распознаю…", busy: true, icon: "waveform",
                              hudIcon: "waveform", accent: .neutral, autoHideAfter: nil, showSpinner: true)
        case .fixing:
            return HUDContent(text: "Обрабатываю текст…", busy: true, icon: "ellipsis",
                              hudIcon: "ellipsis", accent: .neutral, autoHideAfter: nil, showSpinner: true)
        case .done:
            return HUDContent(text: "Готово",
                              busy: false, icon: "checkmark", hudIcon: "checkmark.circle.fill",
                              accent: .success, autoHideAfter: 1.0)
        case .info(let message):
            return HUDContent(text: message.isEmpty ? "Готово" : message,
                              busy: false, icon: "info.circle", hudIcon: "info.circle.fill",
                              accent: .info, autoHideAfter: 1.8)
        case .error(let message):
            return HUDContent(text: message.isEmpty ? "Ошибка" : message,
                              busy: false, icon: "exclamationmark.triangle",
                              hudIcon: "exclamationmark.triangle.fill",
                              accent: .warning, autoHideAfter: 3.0)
        case .idle:
            return nil
        }
    }
}
