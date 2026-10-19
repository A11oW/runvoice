import Foundation

/// Что показывать в HUD для конкретного состояния.
struct HUDContent {
    let text: String
    let busy: Bool
    let icon: String
    let autoHideAfter: TimeInterval?
}

/// Состояние диктовки, которое приложение читает из файла status.
enum DictationState: Equatable {
    case preparing
    case recording
    case transcribing
    case fixing
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
        case "fixing": self = .fixing
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
        case .done(let message), .info(let message), .error(let message): return message
        default: return ""
        }
    }

    /// nil — HUD нужно скрыть.
    var hud: HUDContent? {
        switch self {
        case .preparing:
            return HUDContent(text: "🎤 Готовлю микрофон…", busy: true, icon: "mic", autoHideAfter: nil)
        case .recording:
            return HUDContent(text: "🎤 Слушаю…", busy: true, icon: "mic", autoHideAfter: nil)
        case .transcribing:
            return HUDContent(text: "Распознаю…", busy: true, icon: "waveform", autoHideAfter: nil)
        case .fixing:
            return HUDContent(text: "Исправляю через OpenCode…", busy: true, icon: "ellipsis", autoHideAfter: nil)
        case .done(let message):
            return HUDContent(text: "✅ " + (message.isEmpty ? "Готово" : message),
                              busy: false, icon: "checkmark", autoHideAfter: 2.0)
        case .info(let message):
            return HUDContent(text: "ℹ️ " + (message.isEmpty ? "Готово" : message),
                              busy: false, icon: "info.circle", autoHideAfter: 2.5)
        case .error(let message):
            return HUDContent(text: "⚠️ " + (message.isEmpty ? "Ошибка" : message),
                              busy: false, icon: "exclamationmark.triangle", autoHideAfter: 5.0)
        case .idle:
            return nil
        }
    }
}
