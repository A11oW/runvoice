import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Глобальные хоткеи через активный CGEventTap.
/// Сравнивает код клавиши и модификаторы, совпавшие сочетания потребляет.
final class HotkeyMonitor {
    var onAction: ((DictationAction) -> Void)?

    private var tap: CFMachPort?
    private var toggleHotkey = HotKeySetting()
    private var agentHotkey = HotKeySetting(keyCode: 49,
                                            modifiers: UInt32(controlKey) | UInt32(shiftKey),
                                            display: "⌃⇧Space")
    private var suspended = false

    func start(settings: Settings) {
        update(settings: settings)
        installTap()
    }

    func update(settings: Settings) {
        toggleHotkey = settings.hotkeyToggle
        agentHotkey = settings.hotkeyAgent
    }

    func setSuspended(_ value: Bool) {
        suspended = value
    }

    private func installTap() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
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

                if monitor.shouldConsume(event) { return nil }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.write("event tap: failed (accessibility?)")
            return
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.write("event tap installed")
    }

    private func shouldConsume(_ event: CGEvent) -> Bool {
        if suspended { return false }

        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

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

        if matches(agentHotkey) {
            if !isRepeat {
                Log.write("hotkey fired: agent")
                DispatchQueue.main.async { self.onAction?(.agent) }
            }
            return true
        }

        if matches(toggleHotkey) {
            if !isRepeat {
                Log.write("hotkey fired: toggle")
                DispatchQueue.main.async { self.onAction?(.toggle) }
            }
            return true
        }

        return false
    }
}
