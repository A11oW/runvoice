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
    private let dictationPasteboard = DictationPasteboard()
    private lazy var liveTranscriber: LiveTranscriber = {
        let configured = Int(ProcessInfo.processInfo.environment["WHISPER_SERVER_PORT"] ?? "") ?? 8799
        let port = (1...65535).contains(configured) ? configured : 8799
        return LiveTranscriber(directory: Paths.state,
                               serverURL: URL(string: "http://127.0.0.1:\(port)")!)
    }()
    private var settingsWindow: SettingsWindow?
    private var lastTrust: Bool?
    private var toggleItem: NSMenuItem?
    private var improveItem: NSMenuItem?

    private var lastStateKey = ""
    private var lastState: DictationState?
    private var liveTranscript = ""
    private var liveStartedAt = Date()
    private var closeAt: Date?
    private var isImproving = false
    private var improveToken: UUID?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Снимки не включают микрофон/хоткеи и не сбрасывают статус живой диктовки.
        if startSnapshotMode() { return }
        Log.write("launch status=\(Paths.status.path) screens=\(NSScreen.screens.count)")
        let saved = SettingsStore.load()
        WhisperModelStore.cleanupPartialDownloads()
        HistoryStore.shared.load()
        HistoryStore.shared.prune(maxItems: saved.historyMaxItems, maxDays: saved.historyMaxDays)
        Log.write("settings fix=\(saved.promptFix.count) improve=\(saved.promptImprove.count) improveEnabled=\(saved.improveEnabled) providers=\(saved.providers.count) dictation=\(saved.dictationProvider?.displayTitle ?? "none") improveProfile=\(saved.improveProvider?.displayTitle ?? "none")")
        Log.write("accessibility=\(AXIsProcessTrusted())")
        Log.write("deps " + Dependency.allCases.map { "\($0.title)=\($0.isOK() ? "ok" : "missing")" }.joined(separator: ", "))
        setupStatusItem()
        hud = HUDController()
        hud.setEnabled(saved.showHUD)
        hud.onStop = { [weak self] in
            self?.cancelDictationFromHUD()
        }
        liveTranscriber.onNeedsServer = { [weak self] in self?.runner.warmUp() }
        liveTranscriber.onUpdate = { [weak self] text in
            guard let self, self.lastStateKey == "recording",
                  var content = self.lastState?.hud else { return }
            if self.liveTranscript.isEmpty {
                Log.write("performance: first_preview_ms=\(Int(Date().timeIntervalSince(self.liveStartedAt) * 1000))")
            }
            self.liveTranscript = text
            self.closeAt = nil
            content.transcript = text
            self.hud.present(content)
        }
        hotkeys.onAction = { [weak self] mouseLocation in
            self?.run(mouseLocation: mouseLocation)
        }
        hotkeys.onImprove = { [weak self] mouseLocation in
            self?.performImproveSelection(mouseLocation: mouseLocation)
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

        let t = Timer(timeInterval: 0.06, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        if CommandLine.arguments.contains("--settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.openSettings()
            }
        }

        runner.warmUp()
    }

    private func startSnapshotMode() -> Bool {
        let arguments = CommandLine.arguments
        guard arguments.contains("--snapshot-states") || arguments.contains("--snapshot")
                || arguments.contains("--snapshot-hud") else { return false }
        setupStatusItem()
        hud = HUDController()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            if arguments.contains("--snapshot-states") {
                self.snapshotStates()
            } else if arguments.contains("--snapshot") {
                self.openSettings()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.snapshotSettings() }
            } else {
                let content = HUDContent(text: "Слушаю…", busy: true, icon: "mic",
                                         hudIcon: "mic", accent: .neutral,
                                         autoHideAfter: nil, showLevel: true, showStop: true)
                self.hud.snapshot(to: "/tmp/runvoice-hud.png", content: content) {
                    NSApp.terminate(nil)
                }
            }
        }
        return true
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

    private func showSettings(tab: String?) {
        if settingsWindow == nil {
            settingsWindow = SettingsWindow()
            settingsWindow?.onCaptureStateChanged = { [weak self] capturing in
                self?.hotkeys.setSuspended(capturing)
            }
            settingsWindow?.onSettingsSaved = { [weak self] in
                guard let self else { return }
                self.hud.setEnabled(SettingsStore.load().showHUD)
                if self.lastStateKey == "recording" { self.startLivePreview() }
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
            ("recording-live", HUDContent(text: "Слушаю…", busy: true, icon: "mic",
                                          hudIcon: "mic", accent: .neutral,
                                          autoHideAfter: nil, showLevel: true, showStop: true,
                                          transcript: "Используй Cypress вместо Playwright. Добавь проверку авторизации и запусти тесты в GitHub Actions."), "00:18", 0.62),
            ("transcribing", HUDContent(text: "Распознаю…", busy: true, icon: "waveform",
                                        hudIcon: "waveform", accent: .neutral,
                                        autoHideAfter: nil,
                                        transcript: "Используй Cypress вместо Playwright."), nil, 0),
            ("fixing", HUDContent(text: "Обрабатываю текст…", busy: true, icon: "ellipsis",
                                  hudIcon: "ellipsis", accent: .neutral,
                                  autoHideAfter: nil,
                                  transcript: "Используй Cypress вместо Playwright."), nil, 0),
            ("done", HUDContent(text: "Готово", busy: false, icon: "checkmark",
                                hudIcon: "checkmark.circle.fill",
                                accent: .success, autoHideAfter: nil,
                                transcript: "Используй Cypress вместо Playwright."), nil, 0),
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
            self.settingsWindow?.scrollAIToImprove()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                capture(to: "/tmp/runvoice-settings-improve.png")
                self.settingsWindow?.selectTab("models")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    capture(to: "/tmp/runvoice-settings-models.png")
                    self.settingsWindow?.selectTab("providers")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        capture(to: "/tmp/runvoice-settings-providers.png")
                        self.settingsWindow?.selectTab("history")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            capture(to: "/tmp/runvoice-settings-history.png")
                            self.settingsWindow?.selectTab("hotkeys")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                capture(to: "/tmp/runvoice-settings-hotkeys.png")
                                NSApp.terminate(nil)
                            }
                        }
                    }
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

    private func run(mouseLocation: NSPoint? = nil) {
        if isImproving {
            showImproveHUD("Идёт улучшение текста", icon: "info.circle.fill",
                           accent: .info, duration: 2.5)
            return
        }
        let stopping = lastStateKey == "recording"
        if !["preparing", "recording", "transcribing", "fixing"].contains(lastStateKey) {
            hud.beginSession(mouseLocation: mouseLocation ?? NSEvent.mouseLocation)
        }
        // Whisper.cpp прерывает вычисления при закрытии HTTP-соединения.
        // Освобождаем его сразу на хоткее, до запуска финального распознавания.
        if stopping { liveTranscriber.stop() }
        do {
            try runner.run { [weak self] in
                // Очень быстрый повтор может быть отклонён debounce скрипта.
                // В таком случае запись ещё идёт и предпросмотр нужно вернуть.
                guard stopping, let self, self.lastStateKey == "recording",
                      let raw = try? String(contentsOf: Paths.status, encoding: .utf8),
                      DictationState(raw: raw)?.key == "recording" else { return }
                self.startLivePreview()
            }
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
        liveTranscriber.stop()
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
        performImproveSelection(mouseLocation: NSEvent.mouseLocation)
    }

    private func performImproveSelection(mouseLocation: NSPoint) {
        guard !isImproving else { return }

        if ["preparing", "recording", "transcribing", "fixing"].contains(lastStateKey) {
            showImproveHUD("Идёт диктовка", icon: "info.circle.fill",
                           accent: .info, duration: 2.5)
            return
        }

        hud.beginSession(mouseLocation: mouseLocation)

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
    private func postPaste() -> Bool {
        guard AXIsProcessTrusted() else {
            Log.write("paste: accessibility denied")
            return false
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
        return true
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


    private func completeDictation(fallbackText: String) {
        let result = HistoryStore.consumeLastResult()
        let text = result?.fixed ?? fallbackText
        guard !text.isEmpty else { return }
        dictationPasteboard.deliver(text, restoreClipboard: SettingsStore.load().restoreClipboard) {
            self.postPaste()
        }
        if let ready = result?.readyAtMilliseconds {
            Log.write("performance: ready_to_paste_ms=\(max(0, Int(Date().timeIntervalSince1970 * 1000 - ready)))")
        }
        // Запись истории не задерживает отправку ⌘V и показ результата.
        if let result {
            DispatchQueue.main.async {
                let date = result.timestamp.map { Date(timeIntervalSince1970: $0) } ?? Date()
                HistoryStore.shared.add(text: result.fixed, raw: result.raw,
                                        model: result.model, date: date)
            }
        }
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
        guard state != lastState else { return }

        lastState = state
        lastStateKey = state.key
        closeAt = nil
        Log.write("state=\(state.key) msg=\(state.message)")
        apply(state)
    }

    private func apply(_ state: DictationState) {
        guard var content = state.hud else {
            liveTranscriber.stop()
            micLevel.stop()
            hideHUD()
            return
        }

        if case .preparing = state { liveTranscript = "" }
        if case .recording = state {
            liveTranscript = ""
            liveStartedAt = Date()
            startLivePreview()
        } else {
            liveTranscriber.stop()
        }
        if case .transcribing = state { content.transcript = liveTranscript }

        if case .done(let text) = state {
            completeDictation(fallbackText: text)
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

    private func startLivePreview() {
        let settings = SettingsStore.load()
        guard settings.showHUD,
              let model = WhisperModelStore.activeModel(settings: settings) else {
            liveTranscriber.stop()
            return
        }
        liveTranscriber.start(modelPath: model.path, language: settings.language)
    }

    private func setIcon(_ name: String) {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Runvoice")
        image?.isTemplate = true
        statusItem.button?.image = image
        Log.write("icon=\(name)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        liveTranscriber.stop()
        micLevel.stop()
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
