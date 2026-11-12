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
    private let micLevel = MicLevelMonitor()
    private var settingsWindow: SettingsWindow?
    private var transcribeWindow: AudioTranscribeWindow?
    private var lastTrust: Bool?
    private var toggleItem: NSMenuItem?
    private var improveItem: NSMenuItem?

    private var lastStateKey = ""
    private var closeAt: Date?
    private var isImproving = false
    private var improveToken: UUID?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("launch status=\(Paths.status.path) screens=\(NSScreen.screens.count)")
        let saved = SettingsStore.load()
        WhisperModelStore.cleanupPartialDownloads()
        HistoryStore.shared.load()
        HistoryStore.shared.prune(maxItems: saved.historyMaxItems, maxDays: saved.historyMaxDays)
        Log.write("settings fix=\(saved.promptFix.count) improve=\(saved.promptImprove.count) improveEnabled=\(saved.improveEnabled) providers=\(saved.providers.count) dictation=\(saved.dictationProvider?.displayTitle ?? "none") improveProfile=\(saved.improveProvider?.displayTitle ?? "none")")
        Log.write("accessibility=\(AXIsProcessTrusted())")
        Log.write("deps " + Dependency.allCases.map { "\($0.title)=\($0.isOK() ? "ok" : "missing")" }.joined(separator: ", "))
        setupStatusItem()
        hud = HUDController(statusItem: statusItem)
        hud.setEnabled(saved.showHUD)
        hud.onStop = { [weak self] in
            self?.cancelDictationFromHUD()
        }
        hotkeys.onAction = { [weak self] in
            self?.run()
        }
        hotkeys.onImprove = { [weak self] in
            self?.improveSelection()
        }
        hotkeys.start(settings: saved)
        updateHotkeyTitles(saved)
        micLevel.onLevel = { [weak self] level in
            self?.hud.setLevel(level)
        }
        requestPermissions()

        if !AXIsProcessTrusted() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.promptForAccessibility()
            }
        }

        // сбросить возможный «зависший» статус от прошлого запуска
        try? "idle".write(to: Paths.status, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: Paths.status.path)

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
                let content = HUDContent(text: "Слушаю…", busy: true, icon: "mic",
                                         hudIcon: "mic", accent: .neutral,
                                         autoHideAfter: nil, showLevel: true)
                self?.hud.snapshot(to: "/tmp/runvoice-hud.png", content: content,
                                   timer: "00:07", level: 0.65) {
                    NSApp.terminate(nil)
                }
            }
        }
        if CommandLine.arguments.contains("--snapshot-states") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.snapshotStates()
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
        if let index = CommandLine.arguments.firstIndex(of: "--transcribe-file"),
           index + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.showTranscribe()
                self?.transcribeWindow?.transcribe(url: URL(fileURLWithPath: path))
            }
        }
        if CommandLine.arguments.contains("--snapshot-transcribe") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.showTranscribe()
                self?.transcribeWindow?.showSample(
                    text: """
                    Сегодня мы разберём, как устроена локальная расшифровка аудио. \
                    Модель Whisper работает прямо на этом компьютере: запись не \
                    отправляется в облако. Выберите файл или перетащите его в окно, \
                    дождитесь результата и скопируйте готовый текст.
                    """,
                    fileName: "лекция-2026-11-12.m4a")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    self?.snapshotWindow(self?.transcribeWindow?.window,
                                         to: "/tmp/runvoice-transcribe.png")
                    NSApp.terminate(nil)
                }
            }
        }
        if CommandLine.arguments.contains("--snapshot-transcribe-summary") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.showTranscribe()
                self?.transcribeWindow?.showSummarySample(
                    transcript: """
                    Сегодня мы разберём, как устроена локальная расшифровка аудио. \
                    Модель Whisper работает прямо на этом компьютере: запись не \
                    отправляется в облако. Выберите файл или перетащите его в окно, \
                    дождитесь результата и скопируйте готовый текст.
                    """,
                    summary: """
                    • Расшифровка аудио выполняется локально моделью Whisper.
                    • Запись не отправляется в облако.
                    • Файл можно выбрать вручную или перетащить в окно.
                    • Готовый текст доступен для редактирования и копирования.
                    """,
                    fileName: "лекция-2026-11-12.m4a",
                    prompt: "Сделай саммари в 4 пунктах, деловой стиль.")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    self?.snapshotWindow(self?.transcribeWindow?.window,
                                         to: "/tmp/runvoice-transcribe-summary.png")
                    NSApp.terminate(nil)
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
        improveItem = add(menu, "Улучшить текст", #selector(improveSelection))
        add(menu, "Расшифровать аудио…", #selector(openTranscribe))
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

    @objc private func toggleDictation() { run() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openSettings() { showSettings(tab: nil) }

    @objc private func openTranscribe() { showTranscribe() }

    private func showTranscribe() {
        if transcribeWindow == nil {
            let window = AudioTranscribeWindow(runner: runner)
            window.onOpenSettings = { [weak self] in
                self?.showSettings(tab: "ai")
            }
            transcribeWindow = window
        }
        transcribeWindow?.show()
    }

    private func showSettings(tab: String?) {
        if settingsWindow == nil {
            settingsWindow = SettingsWindow()
            settingsWindow?.onCaptureStateChanged = { [weak self] capturing in
                self?.hotkeys.setSuspended(capturing)
            }
            settingsWindow?.onSettingsSaved = { [weak self] in
                guard let self else { return }
                self.hud.setEnabled(SettingsStore.load().showHUD)
                self.reloadHotkeys()
                self.runner.warmUp()
            }
        }
        settingsWindow?.show()
        if let tab { settingsWindow?.selectTab(tab) }
    }

    private func snapshotStates() {
        let states: [(name: String, content: HUDContent, timer: String?, level: CGFloat)] = [
            ("preparing", HUDContent(text: "Готовлю микрофон…", busy: true, icon: "mic",
                                     hudIcon: "mic", accent: .neutral, autoHideAfter: nil), nil, 0),
            ("recording", HUDContent(text: "Слушаю…", busy: true, icon: "mic",
                                     hudIcon: "mic", accent: .neutral,
                                     autoHideAfter: nil, showLevel: true,
                                     showStop: true), "00:12", 0.62),
            ("transcribing", HUDContent(text: "Распознаю…", busy: true, icon: "waveform",
                                        hudIcon: "waveform", accent: .neutral,
                                        autoHideAfter: nil), nil, 0),
            ("fixing", HUDContent(text: "Обрабатываю текст…", busy: true, icon: "ellipsis",
                                  hudIcon: "ellipsis", accent: .neutral,
                                  autoHideAfter: nil), nil, 0),
            ("done", HUDContent(text: "Готово", busy: false, icon: "checkmark",
                                hudIcon: "checkmark.circle.fill",
                                accent: .success, autoHideAfter: nil), nil, 0),
            ("info", HUDContent(text: "запись не идёт", busy: false, icon: "info.circle",
                                hudIcon: "info.circle.fill",
                                accent: .info, autoHideAfter: nil), nil, 0),
            ("error", HUDContent(text: "речь не распознана (тишина?)", busy: false,
                                 icon: "exclamationmark.triangle",
                                 hudIcon: "exclamationmark.triangle.fill",
                                 accent: .warning, autoHideAfter: nil), nil, 0),
            ("improve", HUDContent(text: "Улучшаю текст…", busy: true, icon: "sparkles",
                                   hudIcon: "sparkles", accent: .neutral,
                                   autoHideAfter: nil), nil, 0),
            ("improve-copied", HUDContent(text: "Улучшено и скопировано", busy: false,
                                          icon: "info.circle",
                                          hudIcon: "info.circle.fill",
                                          accent: .info, autoHideAfter: nil), nil, 0),
        ]

        func capture(_ index: Int) {
            guard index < states.count else {
                NSApp.terminate(nil)
                return
            }
            let state = states[index]
            hud.snapshot(to: "/tmp/runvoice-state-\(state.name).png",
                         content: state.content,
                         timer: state.timer,
                         level: state.level) {
                capture(index + 1)
            }
        }

        capture(0)
    }

    private func snapshotWindow(_ window: NSWindow?, to path: String) {
        guard let view = window?.contentView,
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

        let steps: [(tab: String?, scroll: ((SettingsWindow) -> Void)?, path: String)] = [
            (nil, nil, "/tmp/runvoice-settings-ai.png"),
            (nil, { $0.scrollAIToImprove() }, "/tmp/runvoice-settings-improve.png"),
            (nil, { $0.scrollAIToSummary() }, "/tmp/runvoice-settings-summary.png"),
            ("models", nil, "/tmp/runvoice-settings-models.png"),
            ("providers", nil, "/tmp/runvoice-settings-providers.png"),
            ("history", nil, "/tmp/runvoice-settings-history.png"),
            ("hotkeys", nil, "/tmp/runvoice-settings-hotkeys.png"),
        ]

        settingsWindow?.selectTab("ai")
        func step(_ index: Int) {
            guard index < steps.count else {
                NSApp.terminate(nil)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self else { return }
                if let tab = steps[index].tab {
                    self.settingsWindow?.selectTab(tab)
                }
                if let scroll = steps[index].scroll, let window = self.settingsWindow {
                    scroll(window)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    capture(to: steps[index].path)
                    step(index + 1)
                }
            }
        }
        step(0)
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

    private func run() {
        if isImproving {
            showImproveHUD("Идёт улучшение текста", icon: "info.circle.fill",
                           accent: .info, duration: 2.5)
            return
        }
        do {
            try runner.run()
        } catch DictationRunner.Failure.missingScript {
            showAlert("В ресурсах приложения не найден dictate.sh")
        } catch DictationRunner.Failure.missingModel(let path) {
            showMissingModel(path: path)
        } catch {
            showAlert("Не удалось запустить dictate.sh: \(error.localizedDescription)")
        }
    }

    private func cancelDictationFromHUD() {
        guard ["preparing", "recording"].contains(lastStateKey) else { return }
        do {
            try runner.cancel()
            Log.write("cancel: запрошена отмена записи из HUD")
        } catch {
            let message = "Не удалось отменить запись"
            let content = HUDContent(text: message, busy: false,
                                     icon: "exclamationmark.triangle",
                                     hudIcon: "exclamationmark.triangle.fill",
                                     accent: .warning, autoHideAfter: nil)
            hud.present(content)
            setIcon("exclamationmark.triangle")
            closeAt = Date().addingTimeInterval(4)
            Log.write("cancel: ошибка \(error.localizedDescription)")
        }
    }

    @objc private func improveSelection() {
        guard !isImproving else { return }

        if ["preparing", "recording", "transcribing", "fixing"].contains(lastStateKey) {
            showImproveHUD("Идёт диктовка", icon: "info.circle.fill",
                           accent: .info, duration: 2.5)
            return
        }

        let settings = SettingsStore.load()
        guard settings.improveEnabled else {
            showImproveHUD("Улучшение текста выключено", icon: "info.circle.fill",
                           accent: .info, duration: 3)
            return
        }
        guard let provider = settings.improveProvider else {
            showImproveHUD("Не выбран AI-провайдер для улучшения", icon: "exclamationmark.triangle.fill",
                           accent: .warning, duration: 4)
            return
        }

        switch SelectionService.capture() {
        case .failure(let error):
            showImproveHUD(error.localizedDescription, icon: "info.circle.fill",
                           accent: .info, duration: 3)
        case .success(let context):
            guard context.text.count <= 20_000 else {
                showImproveHUD("Слишком длинный текст (макс. 20 000)", icon: "exclamationmark.triangle.fill",
                               accent: .warning, duration: 4)
                return
            }

            isImproving = true
            let token = UUID()
            improveToken = token
            showImproveHUD("Улучшаю текст…", icon: "sparkles",
                           accent: .neutral, duration: 0, busy: true)
            Log.write("improve: capture \(context.source == .accessibility ? "ax" : "clipboard"), \(context.text.count) символов")

            let prompt = settings.promptImprove.isEmpty ? DefaultPrompts.improve : settings.promptImprove
            Log.write("improve: provider=\(provider.displayTitle) type=\(provider.kind.rawValue) model=\(provider.model)")
            AIClient.generate(provider: provider, system: prompt, text: context.text) { [weak self] result in
                guard let self, self.improveToken == token else { return }

                switch result {
                case .success(let improved):
                    let outcome = SelectionService.replace(context, with: improved)
                    self.isImproving = false
                    self.improveToken = nil
                    switch outcome {
                    case .replaced, .pasted:
                        self.showImproveHUD("Готово", icon: "checkmark.circle.fill",
                                            accent: .success, duration: 2)
                    case .copied:
                        self.showImproveHUD("Улучшено и скопировано", icon: "info.circle.fill",
                                            accent: .info, duration: 4)
                    }
                    Log.write("improve: готово, \(improved.count) символов")
                case .failure(let error):
                    self.isImproving = false
                    self.improveToken = nil
                    self.showImproveHUD(error.localizedDescription, icon: "exclamationmark.triangle.fill",
                                        accent: .warning, duration: 5)
                    Log.write("improve: ошибка \(error.localizedDescription)")
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak self] in
                guard let self, self.improveToken == token, self.isImproving else { return }
                self.isImproving = false
                self.improveToken = nil
                self.showImproveHUD("Модель не ответила", icon: "exclamationmark.triangle.fill",
                                    accent: .warning, duration: 5)
            }
        }
    }

    private func showImproveHUD(_ text: String, icon: String,
                                accent: HUDContent.Accent, duration: TimeInterval,
                                busy: Bool = false) {
        let normalized = text.replacingOccurrences(of: "\n", with: " ")
        let display = normalized.count > 120 ? String(normalized.prefix(117)) + "…" : normalized
        let content = HUDContent(text: display, busy: busy, icon: icon, hudIcon: icon,
                                 accent: accent, autoHideAfter: nil)
        hud.present(content)
        setIcon(icon)
        closeAt = duration > 0 ? Date().addingTimeInterval(duration) : nil
        Log.write("improve: hud \(text)")
    }

    private func showMissingModel(path: String?) {
        let alert = NSAlert()
        if let path {
            alert.messageText = "Модель Whisper недоступна"
            alert.informativeText = "Файл \(path) не найден или повреждён.\nВыберите другую модель в «Настройки» → «Модели»."
        } else {
            alert.messageText = "Модель Whisper не выбрана"
            alert.informativeText = "Откройте «Настройки» → «Модели», скачайте модель или выберите уже скачанную."
        }
        alert.addButton(withTitle: "Открыть настройки")
        alert.addButton(withTitle: "Отмена")
        if alert.runModal() == .alertFirstButtonReturn {
            showSettings(tab: "models")
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
        hotkeys.reload(settings: settings)
        updateHotkeyTitles(settings)
    }

    private func updateHotkeyTitles(_ settings: Settings) {
        toggleItem?.title = "Диктовка   \(settings.hotkeyToggle.display)"
        improveItem?.title = "Улучшить текст   \(settings.hotkeyImprove.display)"
    }


    private func recordHistory() {
        guard let result = HistoryStore.consumeLastResult() else { return }
        let date = result.timestamp.map { Date(timeIntervalSince1970: $0) } ?? Date()
        HistoryStore.shared.add(text: result.fixed, raw: result.raw,
                                model: result.model, date: date)
    }

    private func hideHUD() {
        micLevel.stop()
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
            micLevel.stop()
            hideHUD()
            return
        }

        if case .done = state {
            postPaste()
            recordHistory()
        }

        if content.showLevel {
            micLevel.start()
        } else {
            micLevel.stop()
        }

        hud.present(content)
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
