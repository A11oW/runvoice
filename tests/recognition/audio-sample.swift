import AppKit

private final class SampleInput: DictationAudioRecording {
    var onAudio: ((Data) -> Void)?
    var onFailure: ((Error) -> Void)?
    var url: URL!
    var selectedUID = ""
    var pcm = Data()
    var stops = 0
    var stopError: Error?
    func start(microphone: String, deviceUID: String, url: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        self.url = url; selectedUID = deviceUID
        do { try LiveTranscriber.wav(pcm: pcm).write(to: url); completion(.success(())) }
        catch { completion(.failure(error)) }
    }
    func stop(discard: Bool, completion: @escaping (Result<NativeAudioRecorder.Recording, Error>) -> Void) {
        stops += 1
        if let stopError { completion(.failure(stopError)); return }
        completion(.success(.init(url: url, frames: UInt64(pcm.count / 2))))
    }
    func pause(completion: @escaping (Result<Void, Error>) -> Void) { preconditionFailure("Сэмпл не использует паузу") }
    func resume(completion: @escaping (Result<Void, Error>) -> Void) { preconditionFailure("Сэмпл не использует продолжение") }
}

func testAudioSample() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("runvoice-sample-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    for name in [".git", "app"] {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    try Data().write(to: root.appendingPathComponent("app/Info.plist"))
    try "existing-rule\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
    let input = SampleInput()
    var values = (0..<16000).map { Int16(8192 * sin(Double($0) * 2 * .pi * 440 / 16000)).littleEndian }
    input.pcm = values.withUnsafeMutableBytes { Data($0) }
    let capture = AudioSampleRecorder(recorder: input)
    capture.start(project: root, microphone: "Fixture", deviceUID: "selected-device")
    expect(capture.state == .recording && input.selectedUID == "selected-device", "Сэмпл использует выбранное устройство")
    capture.stop(); capture.stop()
    waitFor("Сэмпл и метрики сохранены") { capture.state == .idle }
    expect(input.stops == 1, "Повторный стоп не дублирует сохранение")
    let saved = try Data(contentsOf: input.url)
    expect(saved == LiveTranscriber.wav(pcm: input.pcm), "WAV сохраняет исходные отсчёты без нормализации")
    let json = input.url.deletingPathExtension().appendingPathExtension("json")
    let metrics = try JSONSerialization.jsonObject(with: Data(contentsOf: json)) as! [String: Any]
    expect(metrics["sample_rate_hz"] as? Int == 16000 && metrics["channels"] as? Int == 1, "Указан формат для анализа PCM")
    expect(metrics["duration_seconds"] as? Double == 1, "Длительность соответствует всему сэмплу")
    expect(abs((metrics["peak_dbfs"] as! Double) + 12.04) < 0.1 && abs((metrics["rms_dbfs"] as! Double) + 15.05) < 0.1,
           "RMS и пик контрольного сигнала рассчитаны в dBFS")
    expect((metrics["frames"] as! [[String: Double]]).count == 16, "Сохранена временная шкала уровней с последним неполным кадром")
    let ignore = try String(contentsOf: root.appendingPathComponent(".gitignore"), encoding: .utf8)
    _ = try AudioSampleRecorder.prepareDirectory(in: root)
    let repeatedIgnore = try String(contentsOf: root.appendingPathComponent(".gitignore"), encoding: .utf8)
    expect(repeatedIgnore == ignore,
           "Правило исключения сэмплов не дублируется")
    expect(ignore.contains("existing-rule") && ignore.contains("/local-audio-samples/"), "Существующие gitignore-правила сохранены")
    input.stopError = NativeAudioRecorder.Failure.empty
    capture.start(project: root, microphone: "Fixture", deviceUID: "selected-device")
    capture.stop()
    expect(capture.state == .idle && !FileManager.default.fileExists(atPath: input.url.path), "Неуспешная запись удаляется, следующая запись разрешена")
    let custom = root.appendingPathComponent("samples with [marks]", isDirectory: true)
    _ = try AudioSampleRecorder.prepareSampleDirectory(at: custom)
    let updatedIgnore = try String(contentsOf: root.appendingPathComponent(".gitignore"), encoding: .utf8)
    expect(updatedIgnore.contains("/samples\\ with\\ \\[marks\\]/"), "Выбранная папка исключается из Git с экранированием имени")
    do {
        _ = try AudioSampleRecorder.prepareSampleDirectory(at: root)
        expect(false, "Нельзя исключить из Git весь корень репозитория")
    } catch { expect(true, "Корень репозитория не выбирается папкой сэмплов") }
    let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: outside) }
    _ = try AudioSampleRecorder.prepareSampleDirectory(at: outside)
    expect(FileManager.default.fileExists(atPath: outside.path), "Поддерживается отдельная папка вне Git-проекта")

    input.stopError = nil
    let panelRecorder = AudioSampleRecorder(recorder: input)
    let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 450),
                          styleMask: [.titled], backing: .buffered, defer: false)
    parent.makeKeyAndOrderFront(nil)
    defer { parent.orderOut(nil) }
    let panel = AudioSamplePanel(recorder: panelRecorder, initialDirectory: custom,
                                 microphone: { ("Fixture", "sheet-device") })
    panel.present(on: parent)
    let controls = descendants(panel.window!.contentView!)
    let record = controls.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "record-audio-sample" }!
    let choose = controls.compactMap { $0 as? NSButton }.first { $0.title == "Выбрать папку сэмпла…" }!
    record.performClick(nil)
    expect(panelRecorder.state == .recording && record.title == "Остановить и сохранить" && !choose.isEnabled,
           "Модалка явно показывает запись и блокирует смену папки")
    expect(input.url.deletingLastPathComponent().path == custom.path && input.selectedUID == "sheet-device",
           "Запись модалки использует выбранную папку и микрофон")
    input.onAudio?(input.pcm)
    let visualizer = controls.compactMap { $0 as? WaveformView }.first!
    expect(visualizer.activityLevel > 0, "PCM записи питает стандартный эквалайзер без распознавания")
    waitFor("Таймер записи продвигается по секундам") { panelRecorder.elapsedSeconds >= 1 }
    let timer = controls.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "sample-timer" }!
    expect(timer.stringValue.hasPrefix("00:01"), "Модалка показывает счётчик секунд")
    panel.dismiss()
    waitFor("Закрытие модалки дожидается сохранения") { parent.attachedSheet == nil && panelRecorder.state == .idle }
    expect(FileManager.default.fileExists(atPath: input.url.path) && visualizer.activityLevel == 0,
           "Закрытие сохраняет WAV и сбрасывает эквалайзер")

}
