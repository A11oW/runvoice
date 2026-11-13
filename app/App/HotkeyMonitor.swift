import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Глобальные хоткеи через активный CGEventTap.
/// Сравнивает код клавиши и модификаторы, совпавшие сочетания потребляет.
final class HotkeyMonitor {
    var onAction: ((NSPoint) -> Void)?
    var onImprove: ((NSPoint) -> Void)?
    var recordingSessionIDProvider: (() -> UUID?)?
    var onFinishRecording: ((UUID) -> Void)?
    var onCancelRecording: ((UUID) -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var toggleHotkey = HotKeySetting()
    private var improveHotkey = HotKeySetting()
    private var suspended = false
    private var stopRecordingOnEnter = false
    private var cancelRecordingOnEscape = false
    private var dictationKeys = DictationKeyPolicy()

    func start(settings: Settings) {
        configure(settings: settings)
        installTap()
        Log.write("hotkeys configured: \(toggleHotkey.display), \(improveHotkey.display)")
    }

    /// Переустановить tap после смены сочетания — без перезапуска приложения.
    func reload(settings: Settings) {
        configure(settings: settings)
        removeTap()
        installTap()
        Log.write("hotkeys reconfigured: \(toggleHotkey.display), \(improveHotkey.display)")
    }

    /// Отделено от установки системного tap для проверки маршрутизации событий.
    func configure(settings: Settings) {
        toggleHotkey = settings.hotkeyToggle
        improveHotkey = settings.hotkeyImprove
        stopRecordingOnEnter = settings.stopRecordingOnEnter
        cancelRecordingOnEscape = settings.cancelRecordingOnEscape
    }

    func setSuspended(_ value: Bool) {
        suspended = value
        // Во время захвата сочетания tap мог быть выключен системой.
        if !value, let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    private func installTap() {
        removeTap()

        let mask = CGEventMask((1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue))
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()

                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = monitor.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }

                if monitor.shouldConsume(event, type: type) { return nil }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.write("event tap: failed (accessibility?)")
            return
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.write("event tap installed")
    }

    private func removeTap() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        source = nil
        tap = nil
    }

    func shouldConsume(_ event: CGEvent, type: CGEventType) -> Bool {
        guard type == .keyDown || type == .keyUp else { return false }
        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let modified = !flags.intersection([.maskControl, .maskShift, .maskAlternate, .maskCommand]).isEmpty
        let decision = dictationKeys.handle(type == .keyDown ? .down : .up,
                                           keyCode: UInt16(keyCode), isRepeat: isRepeat, modified: modified,
                                           finishOnEnter: stopRecordingOnEnter,
                                           cancelOnEscape: cancelRecordingOnEscape, suspended: suspended,
                                           recordingSessionID: recordingSessionIDProvider?())
        switch decision {
        case .consume: return true
        case .finish(let sessionID):
            Log.write("hotkey fired: finish by Enter")
            DispatchQueue.main.async { [weak self] in self?.onFinishRecording?(sessionID) }
            return true
        case .cancel(let sessionID):
            Log.write("hotkey fired: cancel by Esc")
            DispatchQueue.main.async { [weak self] in self?.onCancelRecording?(sessionID) }
            return true
        case .passThrough: break
        }
        // keyUp обслуживает только уже захваченный Enter/Esc. Основные хоткеи
        // по-прежнему вызываются один раз на keyDown, не при отпускании.
        guard type == .keyDown, !suspended else { return false }

        func matches(_ hotkey: HotKeySetting) -> Bool {
            let mods = hotkey.modifiers
            let wantControl = (mods & UInt32(controlKey)) != 0
            let wantShift = (mods & UInt32(shiftKey)) != 0
            let wantOption = (mods & UInt32(optionKey)) != 0
            let wantCommand = (mods & UInt32(cmdKey)) != 0
            return hotkey.keyCode == keyCode
                && flags.contains(.maskControl) == wantControl
                && flags.contains(.maskShift) == wantShift
                && flags.contains(.maskAlternate) == wantOption
                && flags.contains(.maskCommand) == wantCommand
        }

        if matches(improveHotkey) {
            if !isRepeat {
                Log.write("hotkey fired: improve")
                let mouseLocation = NSEvent.mouseLocation
                DispatchQueue.main.async { self.onImprove?(mouseLocation) }
            }
            return true
        }

        if matches(toggleHotkey) {
            if !isRepeat {
                Log.write("hotkey fired: toggle")
                let mouseLocation = NSEvent.mouseLocation
                DispatchQueue.main.async { self.onAction?(mouseLocation) }
            }
            return true
        }

        return false
    }
}
