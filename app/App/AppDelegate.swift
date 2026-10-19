import AppKit
import AVFoundation
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics

// MARK: - Приложение

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hud: HUDController!
    private var timer: Timer?
    private let hotkeys = HotkeyMonitor()
    private let runner = DictationRunner()
    private var settingsWindow: SettingsWindow?
    private var lastTrust: Bool?
    private var toggleItem: NSMenuItem?
    private var agentItem: NSMenuItem?

    private var lastStateKey = ""
    private var closeAt: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("launch status=\(Paths.status.path) screens=\(NSScreen.screens.count)")
        let saved = SettingsStore.load()
        Log.write("settings fix=\(saved.promptFix.count) agent=\(saved.promptAgent.count)")
        Log.write("accessibility=\(AXIsProcessTrusted())")
        Log.write("deps " + Dependency.allCases.map { "\($0.title)=\($0.isOK() ? "ok" : "missing")" }.joined(separator: ", "))
        setupStatusItem()
        hud = HUDController(statusItem: statusItem)
        hud.setEnabled(saved.showHUD)
        hotkeys.onAction = { [weak self] action in
            self?.run(action)
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
                self?.hud.snapshot(to: "/tmp/runvoice-hud.png") {
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

        ensureStatusItemVisible()
    }

    /// Если значок не поместился в меню-бар (вырез/переполнение), показываем
    /// приложение в Dock, чтобы его можно было открыть.
    private func ensureStatusItemVisible() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, !self.statusItemIsVisible() else { return }
            Log.write("status item hidden (menu bar overflow) — Dock icon enabled")
            NSApp.setActivationPolicy(.regular)
        }
    }

    private func statusItemIsVisible() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return true
        }
        let pid = Int(ProcessInfo.processInfo.processIdentifier)

        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? Int) == pid,
                  (window[kCGWindowLayer as String] as? Int) == 25,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue,
                  height <= 40,
                  window[kCGWindowIsOnscreen as String] as? Bool == true else {
                continue
            }
            return true
        }
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
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

    @objc private func toggleDictation() { run(.toggle) }
    @objc private func agentDictation() { run(.agent) }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindow()
            settingsWindow?.onCaptureStateChanged = { [weak self] capturing in
                self?.hotkeys.setSuspended(capturing)
            }
            settingsWindow?.onSettingsSaved = { [weak self] in
                guard let self else { return }
                self.hud.setEnabled(SettingsStore.load().showHUD)
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

    private func run(_ action: DictationAction) {
        do {
            try runner.run(action)
        } catch DictationRunner.Failure.missingScript {
            showAlert("В ресурсах приложения не найден dictate.sh")
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


    private func hideHUD() {
        hud.dismiss()
        closeAt = nil
        setIcon("waveform")     // после завершения — значок приложения
        Log.write("hideHUD")
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
        guard let content = state.hud else {
            hideHUD()
            return
        }

        if case .done = state { postPaste() }

        hud.present(text: content.text, busy: content.busy)
        setIcon(content.icon)

        if let delay = content.autoHideAfter {
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
