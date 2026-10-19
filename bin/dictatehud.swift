// dictatehud.swift — плавающее окно статуса диктовки.
// Читает состояние из файла (аргумент 1) и показывает прогресс.
// Состояния: recording | transcribing | fixing | done | error|текст | idle
// Окно не забирает фокус (nonactivating) и не принимает клики.

import AppKit

let statusPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "/tmp/opencode-dictate/status"

func readStatus() -> (String, String)? {
    guard let raw = try? String(contentsOfFile: statusPath, encoding: .utf8) else { return nil }
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.isEmpty { return nil }
    if let i = s.firstIndex(of: "|") {
        return (String(s[..<i]), String(s[s.index(after: i)...]))
    }
    return (s, "")
}

final class HUD: NSObject, NSApplicationDelegate {
    var panel: NSPanel!
    var spinner: NSProgressIndicator!
    var statusLabel: NSTextField!
    var lastValue = ""
    var lastChange = Date()
    var closeAt: Date?

    func applicationDidFinishLaunching(_ n: Notification) {
        build()
        let t = Timer(timeInterval: 0.15, repeats: true) { _ in self.tick() }
        RunLoop.main.add(t, forMode: .common)
    }

    func build() {
        let w: CGFloat = 320, h: CGFloat = 64
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.appearance = NSAppearance(named: .vibrantDark)
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 14
        bg.layer?.masksToBounds = true
        bg.layer?.borderWidth = 1
        bg.layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor

        spinner = NSProgressIndicator(frame: NSRect(x: 18, y: (h - 18) / 2, width: 18, height: 18))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false

        let title = NSTextField(labelWithString: "Диктовка")
        title.frame = NSRect(x: 50, y: h - 26, width: w - 66, height: 16)
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.textColor = NSColor(white: 1, alpha: 0.55)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.frame = NSRect(x: 50, y: 16, width: w - 66, height: 20)
        statusLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        statusLabel.textColor = .white
        statusLabel.lineBreakMode = .byTruncatingTail

        bg.addSubview(spinner)
        bg.addSubview(title)
        bg.addSubview(statusLabel)
        panel.contentView = bg

        position()
        panel.orderFrontRegardless()
    }

    func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let vf = screen?.visibleFrame else { return }
        let sz = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: vf.midX - sz.width / 2, y: vf.maxY - sz.height - 18))
    }

    func tick() {
        if Date().timeIntervalSince(lastChange) > 300 { NSApp.terminate(nil) }
        guard let (state, msg) = readStatus() else { return }
        if state != lastValue {
            lastValue = state
            lastChange = Date()
            closeAt = nil
            switch state {
            case "preparing":    busy(true,  msg.isEmpty ? "🎤 Готовлю микрофон…" : msg)
            case "recording":    busy(true,  msg.isEmpty ? "🎤 Слушаю…" : msg)
            case "recording_agent": busy(true, "🎤 Слушаю… (инструкция агенту)")
            case "transcribing": busy(true,  msg.isEmpty ? "Распознаю…" : msg)
            case "fixing":       busy(true,  msg.isEmpty ? "Исправляю через OpenCode…" : msg)
            case "done":         busy(false, "✅ " + (msg.isEmpty ? "Готово" : msg)); closeAt = Date().addingTimeInterval(1.5)
            case "info":         busy(false, "ℹ️ " + (msg.isEmpty ? "Готово" : msg)); closeAt = Date().addingTimeInterval(2.5)
            case "error":        busy(false, "⚠️ " + (msg.isEmpty ? "Ошибка" : msg)); closeAt = Date().addingTimeInterval(5)
            case "idle", "quit": NSApp.terminate(nil)
            default: break
            }
        }
        if let closeAt, Date() >= closeAt { NSApp.terminate(nil) }
    }

    func busy(_ busy: Bool, _ text: String) {
        statusLabel.stringValue = text
        if busy { spinner.isHidden = false; spinner.startAnimation(nil) }
        else { spinner.stopAnimation(nil); spinner.isHidden = true }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let hud = HUD()
app.delegate = hud
app.run()
