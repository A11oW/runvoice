import Foundation

/// Перехват физического нажатия до отпускания. Новые нажатия вне записи
/// возвращаются приложению, даже если распознавание ещё не завершилось.
struct DictationKeyPolicy {
    enum Event { case down, up }
    enum Decision: Equatable {
        case passThrough
        case consume
        case finish(UUID)
        case cancel(UUID)
    }

    private var captured = Set<UInt16>()

    mutating func handle(_ event: Event, keyCode: UInt16, isRepeat: Bool = false,
                         modified: Bool = false, finishOnEnter: Bool,
                         cancelOnEscape: Bool = false, suspended: Bool = false,
                         recordingSessionID: UUID?) -> Decision {
        guard keyCode == 36 || keyCode == 76 || keyCode == 53 else { return .passThrough }
        if event == .up {
            return captured.remove(keyCode) == nil ? .passThrough : .consume
        }
        if captured.contains(keyCode) {
            if isRepeat { return .consume }
            // Новый keyDown без autorepeat: прежний keyUp мог потеряться
            // при отключении или переустановке системного tap.
            captured.remove(keyCode)
        }
        let enabled = keyCode == 53 ? cancelOnEscape : finishOnEnter
        guard enabled, !suspended, !modified, !isRepeat, let recordingSessionID else {
            return .passThrough
        }
        captured.insert(keyCode)
        return keyCode == 53 ? .cancel(recordingSessionID) : .finish(recordingSessionID)
    }
}
