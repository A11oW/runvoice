import AppKit
import AVFoundation
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics

// MARK: - Приложение

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var bubble: BubbleView!
    private var spinner: NSProgressIndicator!
    private var label: NSTextField!
    private var timer: Timer?
    private let hotkeys = HotkeyMonitor()
    private var settingsWindow: SettingsWindow?
    private var lastTrust: Bool?
    private var hudEnabled = true
    private var toggleItem: NSMenuItem?
    private var agentItem: NSMenuItem?

    private var lastStateKey = ""
    private var closeAt: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("launch status=\(Paths.status.path) screens=\(NSScreen.screens.count)")
        let saved = SettingsStore.load()
        hudEnabled = saved.showHUD
        Log.write("settings fix=\(saved.promptFix.count) agent=\(saved.promptAgent.count)")
        Log.write("accessibility=\(AXIsProcessTrusted())")
        Log.write("deps " + Dependency.allCases.map { "\($0.title)=\($0.isOK() ? "ok" : "missing")" }.joined(separator: ", "))
        setupStatusItem()
        setupHUD()
        hotkeys.onAction = { [weak self] action in
            self?.run(action == .agent ? "agent" : "toggle")
        }
        hotkeys.start(settings: saved)
        updateHotkeyTitles(saved)
        requestPermissions()

        if !AXIsProcessTrusted() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.promptForAccessibility()
            }
        }

        // сбросить возможный «зависший» статус от прошлого запуска
        try? "idle".write(to: Paths.status, atomically: true, encoding: .utf8)

        let t = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        if CommandLine.arguments.contains("--settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.openSettings()
            }
        }

        if CommandLine.arguments.contains("--snapshot-hud") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self else { return }
                self.showHUD()
                self.busy(true)
                self.label.stringValue = "🎤 Слушаю…"
                self.bubble.needsDisplay = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if let view = self.panel.contentView,
                       let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        let image = NSImage(size: view.bounds.size)
                        image.lockFocus()
                        NSColor.windowBackgroundColor.setFill()
                        view.bounds.fill()
                        if let cg = rep.cgImage, let ctx = NSGraphicsContext.current?.cgContext {
                            ctx.draw(cg, in: view.bounds)
                        }
                        image.unlockFocus()
                        if let tiff = image.tiffRepresentation,
                           let bitmap = NSBitmapImageRep(data: tiff),
                           let png = bitmap.representation(using: .png, properties: [:]) {
                            try? png.write(to: URL(fileURLWithPath: "/tmp/runvoice-hud.png"))
                        }
                    }
                    NSApp.terminate(nil)
                }
            }
        }
        if CommandLine.arguments.contains("--snapshot") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.openSettings()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    self?.snapshotSettings()
                }
            }
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon("waveform")

        let menu = NSMenu()
        let header = NSMenuItem(title: "Runvoice", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        toggleItem = add(menu, "Диктовка", #selector(toggleDictation))
        agentItem = add(menu, "Инструкция агенту", #selector(agentDictation))
        menu.addItem(.separator())
        add(menu, "Настройки…", #selector(openSettings))
        menu.addItem(.separator())
        add(menu, "Открыть лог", #selector(openLog))
        add(menu, "Открыть папку данных", #selector(openData))
        menu.addItem(.separator())
        add(menu, "Выход", #selector(quit))
        statusItem.menu = menu
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc private func toggleDictation() { run("toggle") }
    @objc private func agentDictation() { run("agent") }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindow()
            settingsWindow?.onCaptureStateChanged = { [weak self] capturing in
                self?.hotkeys.setSuspended(capturing)
            }
            settingsWindow?.onSettingsSaved = { [weak self] in
                guard let self else { return }
                self.hudEnabled = SettingsStore.load().showHUD
                if !self.hudEnabled { self.panel?.orderOut(nil) }
                self.reloadHotkeys()
            }
        }
        settingsWindow?.show()
    }

    private func snapshotSettings() {
        func capture(to path: String) {
            guard let view = settingsWindow?.window?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            let image = NSImage(size: view.bounds.size)
            image.lockFocus()
            NSColor.windowBackgroundColor.setFill()
            view.bounds.fill()
            if let cg = rep.cgImage, let ctx = NSGraphicsContext.current?.cgContext {
                ctx.draw(cg, in: view.bounds)
            }
            image.unlockFocus()
            if let tiff = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff),
               let png = bitmap.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
            }
        }

        capture(to: "/tmp/runvoice-settings.png")
        settingsWindow?.selectTab("ai")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            capture(to: "/tmp/runvoice-settings-ai.png")
            self.settingsWindow?.selectTab("prompt")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                capture(to: "/tmp/runvoice-settings-prompt.png")
                self.settingsWindow?.selectTab("hotkeys")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    capture(to: "/tmp/runvoice-settings-hotkeys.png")
                    NSApp.terminate(nil)
                }
            }
        }
    }

    @objc private func openAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openLog() {
        if !FileManager.default.fileExists(atPath: Paths.log.path) {
            FileManager.default.createFile(atPath: Paths.log.path, contents: Data())
        }
        NSWorkspace.shared.open(Paths.log)
    }

    @objc private func openData() { NSWorkspace.shared.open(Paths.state) }

    // MARK: - Запуск пайплайна

    private func run(_ action: String) {
        guard let script = Paths.script else {
            showAlert("В ресурсах приложения не найден dictate.sh")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path, action]

        var env = ProcessInfo.processInfo.environment
        env["DICTATE_STATE_DIR"] = Paths.state.path
        env["HUD_BIN"] = "/nonexistent"   // окно рисует само приложение
        env["DICTATE_NOTIFY"] = "0"
        env["DICTATE_NO_PASTE"] = "1"     // ⌘V отправляет само приложение

        let settings = SettingsStore.load()
        if !settings.promptFix.isEmpty { env["DICTATE_PROMPT_FIX"] = settings.promptFix }
        if !settings.promptAgent.isEmpty { env["DICTATE_PROMPT_AGENT"] = settings.promptAgent }
        if !settings.language.isEmpty { env["WHISPER_LANG"] = settings.language }
        if !settings.provider.isEmpty { env["OC_PROVIDER"] = settings.provider }
        if !settings.model.isEmpty { env["OC_MODEL_ID"] = settings.model }
        if !settings.baseURL.isEmpty { env["OC_BASE_URL"] = settings.baseURL }
        if settings.restoreClipboard { env["DICTATE_RESTORE_CLIPBOARD"] = "1" }
        let base = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = base + ":" + (env["PATH"] ?? "")
        p.environment = env

        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            showAlert("Не удалось запустить dictate.sh: \(error.localizedDescription)")
        }
    }

    /// Отправляет ⌘V из процесса приложения (у него есть Accessibility).
    private func postPaste() {
        guard AXIsProcessTrusted() else {
            Log.write("paste: accessibility denied")
            return
        }
        let key: CGKeyCode = 9   // физическая клавиша V
        let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        usleep(30_000)
        up?.post(tap: .cghidEventTap)
        Log.write("paste: app cgEvent")
    }

    private func showAlert(_ text: String) {
        let a = NSAlert()
        a.messageText = "Runvoice"
        a.informativeText = text
        a.runModal()
    }

    // MARK: - Хоткеи

    private func reloadHotkeys() {
        let settings = SettingsStore.load()
        hotkeys.update(settings: settings)
        updateHotkeyTitles(settings)
    }

    private func updateHotkeyTitles(_ settings: Settings) {
        toggleItem?.title = "Диктовка   \(settings.hotkeyToggle.display)"
        agentItem?.title = "Инструкция агенту   \(settings.hotkeyAgent.display)"
    }


    // MARK: - Окно статуса

    private func setupHUD() {
        let w: CGFloat = 330
        let body: CGFloat = 64
        let h: CGFloat = body + 9   // тело + хвостик

        bubble = BubbleView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        bubble.bodyHeight = body

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

        spinner = NSProgressIndicator(frame: NSRect(x: 18, y: (body - 18) / 2, width: 18, height: 18))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false

        let title = NSTextField(labelWithString: "Runvoice")
        title.frame = NSRect(x: 50, y: body - 26, width: w - 66, height: 16)
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.textColor = NSColor(white: 1, alpha: 0.55)

        label = NSTextField(labelWithString: "")
        label.frame = NSRect(x: 50, y: 16, width: w - 66, height: 20)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail

        bubble.addSubview(spinner)
        bubble.addSubview(title)
        bubble.addSubview(label)
        panel.contentView = bubble
    }

    private func showHUD() {
        guard hudEnabled else {
            if panel?.isVisible == true { panel.orderOut(nil) }
            return
        }
        if !panel.isVisible {
            placeHUD()
            panel.orderFrontRegardless()
            Log.write("showHUD frame=\(panel.frame) visible=\(panel.isVisible) screen=\(panel.screen?.frame ?? .zero)")
        }
    }

    private func placeHUD() {
        let size = panel.frame.size

        guard let button = statusItem.button, let window = button.window else {
            let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
                ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            panel.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.maxY - size.height))
            bubble.tailX = size.width / 2
            bubble.needsDisplay = true
            return
        }

        let rectInWindow = button.convert(button.bounds, to: nil)
        let screenRect = window.convertToScreen(rectInWindow)
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var x = screenRect.midX - size.width / 2
        x = max(vf.minX + 6, min(x, vf.maxX - size.width - 6))

        // хвостик смотрит в иконку, бабл висит сразу под меню-баром
        panel.setFrameOrigin(NSPoint(x: x, y: vf.maxY - size.height + 2))
        bubble.tailX = screenRect.midX - x
        bubble.needsDisplay = true
    }

    private func hideHUD() {
        panel?.orderOut(nil)
        closeAt = nil
        setIcon("waveform")     // после завершения — значок приложения
        Log.write("hideHUD")
    }

    private func busy(_ on: Bool) {
        if on { spinner.isHidden = false; spinner.startAnimation(nil) }
        else { spinner.stopAnimation(nil); spinner.isHidden = true }
    }

    private func tick() {
        let trust = AXIsProcessTrusted()
        if trust != lastTrust {
            lastTrust = trust
            Log.write("accessibility=\(trust)")
        }
        if let closeAt, Date() >= closeAt { hideHUD(); return }
        guard let raw = try? String(contentsOf: Paths.status, encoding: .utf8) else { return }
        guard let state = DictationState(raw: raw) else { return }
        guard state.key != lastStateKey else { return }

        lastStateKey = state.key
        closeAt = nil
        Log.write("state=\(state.key) msg=\(state.message)")
        apply(state)
    }

    private func apply(_ state: DictationState) {
        guard let hud = state.hud else {
            hideHUD()
            return
        }

        if case .done = state { postPaste() }

        showHUD()
        busy(hud.busy)
        label.stringValue = hud.text
        setIcon(hud.icon)

        if let delay = hud.autoHideAfter {
            closeAt = Date().addingTimeInterval(delay)
        }
    }

    private func setIcon(_ name: String) {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Runvoice")
        image?.isTemplate = true
        statusItem.button?.image = image
        Log.write("icon=\(name)")
    }

    // MARK: - Разрешения

    private func promptForAccessibility() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Runvoice нужен доступ Accessibility"
        alert.informativeText = "Без этого разрешения приложение не сможет вставлять распознанный текст в активное окно.\n\nВключите Runvoice в списке Accessibility."
        alert.addButton(withTitle: "Открыть настройки")
        alert.addButton(withTitle: "Позже")
        if alert.runModal() == .alertFirstButtonReturn {
            openAccessibility()
        }
    }

    private func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}
