import AppKit

/// Настоящая карточка и часы, включая новую сессию без промежуточного idle tick.
func testPauseHUD() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("runvoice-pause-hud-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let hud = HUDController()
    defer { hud.dismiss() }
    let point = NSPoint(x: 500, y: 500)
    var recording = DictationState.recording.hud!
    recording.transcript = "Используй Cypress вместо Playwright и сохрани результат."
    var paused = DictationState.paused.hud!
    paused.transcript = recording.transcript
    func capture(_ name: String, _ content: HUDContent) throws -> [String: Any] {
        var complete = false
        let png = folder.appendingPathComponent(name + ".png")
        hud.snapshot(to: png.path, content: content) { complete = true }
        waitFor("Снимок настоящего HUD завершён") { complete }
        return try JSONSerialization.jsonObject(with: Data(contentsOf: png.deletingPathExtension().appendingPathExtension("json"))) as! [String: Any]
    }
    hud.present(recording)
    spin(0.07)
    let active = try capture("active", recording)
    expect((active["recordingSeconds"] as! Double) > 0, "Первый показ запускает часы при автоматическом создании позиции")
    hud.present(paused)
    let first = try capture("paused", paused)
    spin(0.08)
    hud.present(paused)
    let repeated = try capture("paused-again", paused)
    expect(first["preview"] as? String == active["preview"] as? String, "Пауза сохраняет видимый текст настоящего HUD")
    expect(first["width"] as? Double == active["width"] as? Double && first["height"] as? Double == active["height"] as? Double,
           "Пауза сохраняет размеры карточки")
    expect(first["pauseIndicatorVisible"] as? Bool == true && first["spectrumVisible"] as? Bool == false,
           "На паузе подпись заменяет спектр")
    expect(active["pauseAction"] as? String == "pause" && first["pauseAction"] as? String == "resume",
           "Пауза меняет действие первой кнопки на продолжение")
    expect(active["pauseDiameter"] as? Double == 18 && active["recordDiameter"] as? Double == 8,
           "Серый фон уменьшен до 18 pt, красная точка — 8 pt")
    expect(active["pauseGlyph"] as? String == "record" && first["pauseGlyph"] as? String == "pause",
           "Запись показывает точку, пауза — красные штрихи")
    expect(active["recordingPulseVisible"] as? Bool == true && first["recordingPulseVisible"] as? Bool == false,
           "Аура видна только при записи")
    for metadata in [active, first] {
        expect((metadata["pauseX"] as! Double) + Double(HUDLayout.actionSize) < (metadata["stopX"] as! Double)
            && (metadata["stopX"] as! Double) + Double(HUDLayout.actionSize) < (metadata["timerX"] as! Double),
               "Обе кнопки слева от таймера, пауза перед стопом, без пересечений")
        let centers = metadata["rowCenters"] as! [String: Double]
        expect(centers.values.allSatisfy { abs($0 - centers["timer"]!) < 0.01 },
               "Кнопки, таймер и индикация на одной оси")
    }
    expect(first["recordingSeconds"] as? Double == repeated["recordingSeconds"] as? Double, "Часы замерли при повторной отрисовке паузы")
    hud.present(recording)
    spin(0.07)
    let resumed = try capture("resumed", recording)
    expect((resumed["recordingSeconds"] as! Double) > (first["recordingSeconds"] as! Double), "Продолжение возобновляет часы")
    expect(resumed["preview"] as? String == active["preview"] as? String, "Продолжение сохраняет предварительный текст")
    // Между отменой и новым стартом поллинг может не увидеть ни idle, ни preparing.
    hud.beginSession(mouseLocation: point)
    let fresh = DictationState.recording.hud!
    hud.present(fresh)
    let next = try capture("next-session", fresh)
    expect((next["recordingSeconds"] as! Double) < 0.1, "Новая сессия сбрасывает часы без промежуточного idle")
    expect(next["preview"] as? String == "", "Новая сессия не показывает прежний черновик")

    // Настоящие NSButton, без публикации событий мыши и без микрофона.
    func action(_ label: String) -> NSButton {
        NSApp.windows.compactMap { $0.contentView as? NSButton }
            .first { $0.window?.isVisible == true && $0.accessibilityLabel() == label }!
    }
    var toggles = 0
    var stops = 0
    hud.onTogglePause = {
        toggles += 1
        hud.present(toggles.isMultiple(of: 2) ? recording : paused)
    }
    hud.onStop = { stops += 1; hud.dismiss() }
    hud.present(recording)
    let keyWindow = NSApp.keyWindow
    let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let pauseButton = action("Приостановить запись")
    let stopButton = action("Остановить запись и отменить диктовку")
    func auraInk() -> Double {
        pauseButton.displayIfNeeded()
        let bounds = pauseButton.bounds
        let bitmap = pauseButton.bitmapImageRepForCachingDisplay(in: bounds)!
        pauseButton.cacheDisplay(in: bounds, to: bitmap)
        var ink = 0.0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let dx = (Double(x) + 0.5) / Double(bitmap.pixelsWide) * bounds.width - bounds.midX
                let dy = (Double(y) + 0.5) / Double(bitmap.pixelsHigh) * bounds.height - bounds.midY
                guard hypot(dx, dy) > 5.5, hypot(dx, dy) < 8.5,
                      let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                ink += max(0, color.redComponent - color.greenComponent)
            }
        }
        return ink
    }
    hud.setSpectrum(Array(repeating: 0, count: WaveformLevels.count))
    let silentInk = auraInk()
    hud.setSpectrum(Array(repeating: 1, count: WaveformLevels.count))
    spin(0.85)
    let loudInk = auraInk()
    expect(loudInk > silentInk, "Заполненная аура расширяется с ростом спектра")
    hud.present(recording)
    expect(abs(auraInk() - loudInk) < 0.01, "Обновление preview сохраняет уровень ауры")
    let mouse = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: pauseButton.window!.windowNumber,
                                      context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
    pauseButton.mouseEntered(with: mouse)
    spin(0.20)
    expect(abs(auraInk() - loudInk) < 0.01 && toggles == 0, "Наведение сохраняет заполненную ауру и активную запись")
    pauseButton.mouseExited(with: mouse)
    spin(0.20)
    expect(abs(auraInk() - loudInk) < 0.01 && toggles == 0, "Уход мыши сохраняет уровень ауры без переключения сессии")
    expect(pauseButton.window?.canBecomeKey == false && stopButton.window?.canBecomeKey == false,
           "Панели обеих кнопок не могут забрать фокус")
    expect(pauseButton.window!.frame.maxX < stopButton.window!.frame.minX,
           "Между отдельными кликабельными панелями остаётся просвет")
    pauseButton.performClick(nil)
    expect(toggles == 1 && stops == 0, "Клик паузы вызывает только переключение паузы")
    spin(0.20)
    expect(auraInk() < loudInk, "На паузе заполненной ауры нет")
    let resume = action("Продолжить запись")
    expect(resume === pauseButton, "Продолжение использует ту же кнопку на том же месте")
    resume.performClick(nil)
    expect(toggles == 2 && stops == 0, "Клик продолжения возобновляет ту же запись")
    hud.setSpectrum(Array(repeating: 1, count: WaveformLevels.count))
    spin(0.85)
    expect(abs(auraInk() - loudInk) < 0.01, "Продолжение возвращает реакцию ауры на спектр")
    expect(NSApp.keyWindow === keyWindow && NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost,
           "Кнопки не активируют окно Runvoice или другое приложение")
    hud.present(paused)
    stopButton.performClick(nil)
    stopButton.performClick(nil)
    expect(stops == 1 && toggles == 2, "Стоп доступен на паузе и вызывает отмену один раз")
    expect(pauseButton.window?.isVisible == false && stopButton.window?.isVisible == false,
           "Закрытие HUD скрывает обе кнопки")
    hud.present(DictationState.transcribing.hud!)
    expect(pauseButton.window?.isVisible == false && stopButton.window?.isVisible == false,
           "Во время обработки обе кнопки скрыты")
    pauseButton.performClick(nil)
    stopButton.performClick(nil)
    expect(stops == 1 && toggles == 2, "Скрытые действия не меняют завершённую запись")
    hud.setPreviewOptions(RecognitionPreview(enabled: false, lineCount: 3))
    hud.present(recording)
    expect(action("Приостановить запись").isEnabled && action("Остановить запись и отменить диктовку").isEnabled,
           "Обе кнопки доступны при отключённом предпросмотре")
    let compact = try capture("compact", recording)
    expect(compact["height"] as? Double == Double(HUDLayout.rowHeight), "Без предпросмотра HUD сохраняет высоту 40 pt")
}
