import AVFoundation
import Foundation

private var checks = 0
private var diagnostic = ""
private func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    precondition(value(), message)
}
private func spin(_ duration: TimeInterval = 0.03) {
    let end = Date().addingTimeInterval(duration)
    while Date() < end { RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.01))) }
}
private func wait(_ message: String, _ condition: () -> Bool) {
    let end = Date().addingTimeInterval(4)
    while !condition(), Date() < end { spin() }
    if !condition(), !diagnostic.isEmpty { FileHandle.standardError.write(Data((diagnostic + "\n").utf8)) }
    expect(condition(), message)
}
private func status() -> String {
    ((try? String(contentsOf: Paths.status, encoding: .utf8)) ?? "").components(separatedBy: "|")[0]
}
private func samples(_ pcm: Data) -> [Int16] {
    stride(from: 0, to: pcm.count - pcm.count % 2, by: 2).map {
        Int16(bitPattern: UInt16(pcm[$0]) | UInt16(pcm[$0 + 1]) << 8)
    }
}

/// Управляемый источник вместо AUHAL; ресемплинг, запись WAV и доставка PCM
/// выполняются настоящим PCMSink. Пауза выключает источник до drain очереди.
private final class TestRecorder: DictationAudioRecording {
    var onAudio: ((Data) -> Void)?
    var onFailure: ((Error) -> Void)?
    private let queue = DispatchQueue(label: "Runvoice.pause-tests.pcm")
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var sink: PCMSink?
    private(set) var sourceRunning = false
    private(set) var pauseCalls = 0
    private(set) var resumeCalls = 0
    private(set) var stopCalls = 0
    private(set) var stopsCompleted = 0
    private(set) var url: URL?
    private(set) var delivered = Data()
    var holdPause = false
    var holdResume = false
    var holdStart = false
    var resumeError: Error?
    var pendingStart: (() -> Void)?
    var pendingPause: (() -> Void)?
    var pendingResume: (() -> Void)?

    func start(microphone: String, deviceUID: String, url: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            let converter = AVAudioConverter(from: format, to: format)!
            self.url = url
            delivered.removeAll()
            sink = try PCMSink(url: url, converter: converter, output: format,
                onAudio: { [weak self] pcm in
                    self?.delivered.append(pcm)
                    self?.onAudio?(pcm)
                }, onLevel: nil, onFailure: onFailure)
            let callback = { [weak self] in
                if self?.sink != nil { self?.sourceRunning = true }
                completion(.success(()))
            }
            if holdStart { pendingStart = callback }
            else { callback() }
        } catch { completion(.failure(error)) }
    }

    func emit(_ value: Int16, frames: Int = 6400) {
        guard sourceRunning, let sink else { return }
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        input.frameLength = AVAudioFrameCount(frames)
        for index in 0..<frames { input.floatChannelData![0][index] = Float(value) / 32768 }
        queue.async { sink.consume(input) }
    }

    func pause(completion: @escaping (Result<Void, Error>) -> Void) {
        pauseCalls += 1
        sourceRunning = false
        queue.async { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                let callback = { completion(.success(())) }
                if self.holdPause { self.pendingPause = callback }
                else { callback() }
            }
        }
    }

    func resume(completion: @escaping (Result<Void, Error>) -> Void) {
        resumeCalls += 1
        let callback = { [weak self] in
            guard let self else { return }
            if let error = self.resumeError { completion(.failure(error)) }
            else {
                // Поздний mock callback сообщает успех, но остановленный источник
                // не запускает. Контроллер также обязан отклонить этот callback.
                if self.sink != nil { self.sourceRunning = true }
                completion(.success(()))
            }
        }
        if holdResume { pendingResume = callback }
        else { callback() }
    }

    func stop(discard: Bool, completion: @escaping (Result<NativeAudioRecorder.Recording, Error>) -> Void) {
        stopCalls += 1
        sourceRunning = false
        let sink = self.sink
        self.sink = nil
        queue.async {
            let result: Result<NativeAudioRecorder.Recording, Error>
            do {
                guard let sink else { throw NativeAudioRecorder.Failure.empty }
                let recording = try sink.finish()
                if discard { try? FileManager.default.removeItem(at: recording.url) }
                result = .success(recording)
            } catch { result = .failure(error) }
            DispatchQueue.main.async { [self] in
                stopsCompleted += 1
                completion(result)
            }
        }
    }

    func releasePause() { let callback = pendingPause; pendingPause = nil; callback?() }
    func releaseResume() { let callback = pendingResume; pendingResume = nil; callback?() }
    func releaseStart() { let callback = pendingStart; pendingStart = nil; callback?() }
}

private final class TestPipeline: DictationPipeline {
    private(set) var wavs: [Data] = []
    private(set) var transcripts: [String?] = []
    private(set) var warmups = 0
    private(set) var stops = 0
    func finish(audio: URL, transcript: String?, settings: Settings, completion: @escaping () -> Void) throws {
        wavs.append(try Data(contentsOf: audio))
        transcripts.append(transcript)
        try "done|Готово".write(to: Paths.status, atomically: true, encoding: .utf8)
        DispatchQueue.main.async(execute: completion)
    }
    func warmUp(settings: Settings?, completion: (() -> Void)?) { warmups += 1; completion?() }
    func stopProcessing() { stops += 1 }
}

private let fixture = Paths.support.appendingPathComponent("fixture-tiny.bin")
try (Data("lmgg".utf8) + Data(count: 1_000_001)).write(to: fixture)
private func settings(_ model: FluidModel? = nil, preview: Bool = false) -> Settings {
    var settings = Settings()
    settings.whisperModelPath = fixture.path
    settings.providers = []
    settings.dictationProviderID = nil
    settings.improveProviderID = nil
    settings.previewEnabled = preview
    if let model { settings.recognitionTechnology = .fluidAudio; settings.fluidModel = model }
    return settings
}
private func start(_ recorder: TestRecorder, _ pipeline: TestPipeline) throws -> (DictationSession, UUID) {
    let saved = settings()
    let session = DictationSession(runner: pipeline, recorder: recorder, loadSettings: { saved })
    try session.toggle()
    expect(session.isRecording && recorder.sourceRunning, "Начата одна активная запись")
    return (session, session.recordingSessionID!)
}
private func pause(_ session: DictationSession, _ id: UUID) {
    expect(session.togglePause(expectedSessionID: id), "Пауза относится к текущему UUID")
    wait("Пауза подтверждена после drain") { status() == "paused" }
    expect(session.isBusy && !session.isRecording && session.pausedSessionID == id, "Пауза сохраняет занятую сессию и её UUID")
}
private func finish(_ session: DictationSession, _ id: UUID, _ pipeline: TestPipeline) {
    expect(session.finishRecording(expectedSessionID: id), "Enter завершает текущую запись")
    wait("Финальный конвейер завершён") { !session.isBusy }
    expect(pipeline.wavs.count == 1, "Одна финализация без повторного результата")
}
private func checkWAV(_ wav: Data, _ expected: [Int16]) {
    if wav.count != expected.count * 2 + 44 {
        let counts = Dictionary(grouping: samples(Data(wav.dropFirst(44))), by: { $0 }).mapValues(\.count)
        FileHandle.standardError.write(Data("WAV diagnostic: got=\(wav.count) expected=\(expected.count * 2 + 44) values=\(counts)\n".utf8))
    }
    expect(wav.prefix(4) == Data("RIFF".utf8) && wav.count == expected.count * 2 + 44, "Финальный WAV имеет корректную длину")
    expect(samples(Data(wav.dropFirst(44))) == expected, "WAV содержит весь A+C и не содержит разговор B")
    let length = wav[40..<44].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
    expect(length == UInt32(expected.count * 2), "Заголовок WAV финализирован один раз с полной длиной")
}

// Сегмент перед Space специально оставлен в processing: drain должен доставить
// его в потоковый ASR и WAV до подтверждения паузы. B в источник не принимается.
do {
    let recorder = TestRecorder(), pipeline = TestPipeline()
    let (session, id) = try start(recorder, pipeline)
    recorder.emit(2000)
    pause(session, id)
    let before = recorder.delivered
    recorder.emit(18_000)
    spin(0.12)
    expect(recorder.delivered == before && !recorder.sourceRunning, "На паузе источник выключен и PCM не растёт")
    expect(pipeline.wavs.isEmpty && pipeline.warmups == 0, "Пауза не финализирует и не прогревает ASR")
    session.prewarm()
    expect(pipeline.warmups == 0, "Фоновый прогрев не меняет backend занятой сессии на паузе")
    expect(session.togglePause(expectedSessionID: id), "Space продолжает тот же UUID")
    wait("Продолжение записи") { session.isRecording }
    recorder.emit(-4000)
    finish(session, id, pipeline)
    checkWAV(pipeline.wavs[0], Array(repeating: 2000, count: 6400) + Array(repeating: -4000, count: 6400))
    expect(recorder.delivered == Data(pipeline.wavs[0].dropFirst(44)), "Финальный WAV и доставленный PCM совпадают, включая drain")
    expect(!FileManager.default.fileExists(atPath: recorder.url!.path), "Временный WAV удалён после конвейера")
}

// Enter и основной хоткей завершают прямо из паузы, не включая микрофон.
for primaryHotkey in [false, true] {
    let recorder = TestRecorder(), pipeline = TestPipeline()
    let (session, id) = try start(recorder, pipeline)
    recorder.emit(2000)
    pause(session, id)
    if primaryHotkey { try session.toggle(); wait("Основной хоткей завершил паузу") { !session.isBusy } }
    else { finish(session, id, pipeline) }
    expect(pipeline.wavs.count == 1 && recorder.resumeCalls == 0, "Завершение паузы не возобновляет вход")
    checkWAV(pipeline.wavs[0], Array(repeating: 2000, count: 6400))
}

// Esc и завершение приложения удаляют WAV, не запуская ASR/AI/вставку.
for shutdown in [false, true] {
    let recorder = TestRecorder(), pipeline = TestPipeline()
    let (session, id) = try start(recorder, pipeline)
    recorder.emit(2000); pause(session, id)
    if shutdown { session.shutdown() }
    else { expect(session.cancelRecording(expectedSessionID: id), "Esc отменяет паузу") }
    wait("Отменённый recorder дренирован") { recorder.stopsCompleted == 1 }
    expect(!session.isBusy && !recorder.sourceRunning && pipeline.wavs.isEmpty, "Отмена не запускает финальный конвейер")
    expect(!FileManager.default.fileExists(atPath: recorder.url!.path), "Отменённый WAV удалён")
}

do {
    let recorder = TestRecorder(), pipeline = TestPipeline()
    recorder.holdStart = true
    let saved = settings()
    let session = DictationSession(runner: pipeline, recorder: recorder, loadSettings: { saved })
    try session.toggle()
    expect(session.isBusy && session.recordingSessionID == nil && !recorder.sourceRunning,
           "Preparing не открывает Space/Enter до завершённого старта")
    session.cancel()
    wait("Отмена preparing закрыла recorder") { recorder.stopsCompleted == 1 }
    recorder.releaseStart(); spin()
    expect(!session.isBusy && !recorder.sourceRunning && pipeline.wavs.isEmpty,
           "Поздний start callback после отмены preparing не запускает запись")
    expect(!FileManager.default.fileExists(atPath: recorder.url!.path), "WAV отменённой подготовки удалён")
}

// Два физических Space во время паузы I/O сериализуются в pause→resume.
do {
    let recorder = TestRecorder(), pipeline = TestPipeline()
    recorder.holdPause = true; recorder.holdResume = true
    let (session, id) = try start(recorder, pipeline)
    recorder.emit(2000)
    expect(session.togglePause(expectedSessionID: id), "Первый быстрый Space принят")
    expect(session.togglePause(expectedSessionID: id), "Второй быстрый Space принят до pause callback")
    wait("Mock pause готов к drain") { recorder.pendingPause != nil }
    expect(recorder.pauseCalls == 1 && recorder.resumeCalls == 0, "Одновременно выполняется один переход I/O")
    recorder.releasePause()
    expect(recorder.resumeCalls == 1 && !session.isRecording, "Resume следует только после завершённого pause")
    recorder.releaseResume()
    expect(session.isRecording && session.recordingSessionID == id, "Быстрое двойное нажатие сохраняет активную сессию")
    finish(session, id, pipeline)
}

// Завершение/отмена имеют приоритет и над pause, и над resume callbacks.
for resuming in [false, true] {
    for cancel in [false, true] {
        let recorder = TestRecorder(), pipeline = TestPipeline()
        let (session, id) = try start(recorder, pipeline)
        recorder.emit(2000)
        if resuming {
            pause(session, id); recorder.holdResume = true
            _ = session.togglePause(expectedSessionID: id)
            expect(recorder.pendingResume != nil, "Resume callback удерживается")
        } else {
            recorder.holdPause = true
            _ = session.togglePause(expectedSessionID: id)
            wait("Pause callback удерживается") { recorder.pendingPause != nil }
        }
        if cancel { expect(session.cancelRecording(expectedSessionID: id), "Esc действует во время перехода") }
        else { expect(session.finishRecording(expectedSessionID: id), "Enter действует во время перехода") }
        wait("Terminal stop завершён") { recorder.stopsCompleted == 1 }
        if !cancel { wait("Terminal pipeline завершён") { !session.isBusy } }
        recorder.releasePause(); recorder.releaseResume(); spin()
        expect(!session.isBusy && !recorder.sourceRunning, "Поздний callback не возвращает сессию к записи")
        expect(pipeline.wavs.count == (cancel ? 0 : 1), "Поздний callback не финализирует запись второй раз")
        expect(recorder.resumeCalls == (resuming ? 1 : 0), "Поздний pause не вызывает новый resume после Enter/Esc")
    }
}

do {
    let recorder = TestRecorder(), pipeline = TestPipeline()
    let (session, oldID) = try start(recorder, pipeline)
    recorder.emit(2000); pause(session, oldID)
    _ = session.cancelRecording(expectedSessionID: oldID)
    wait("Старая запись закрыта") { recorder.stopsCompleted == 1 }
    try session.toggle()
    let newID = session.recordingSessionID!
    expect(newID != oldID, "Новая диктовка получает новый UUID")
    expect(!session.togglePause(expectedSessionID: oldID) && !session.finishRecording(expectedSessionID: oldID)
        && !session.cancelRecording(expectedSessionID: oldID), "Устаревшие Space/Enter/Esc не затрагивают новую запись")
    expect(session.isRecording, "Новая запись осталась активной после устаревших действий")
    session.cancel(); wait("Новая запись очищена") { recorder.stopsCompleted == 2 }
}

do {
    let recorder = TestRecorder(), pipeline = TestPipeline()
    let (session, id) = try start(recorder, pipeline)
    recorder.emit(2000); pause(session, id)
    recorder.resumeError = NativeAudioRecorder.Failure.configuration
    _ = session.togglePause(expectedSessionID: id)
    wait("Ошибка возобновления закрыла вход") { recorder.stopsCompleted == 1 }
    expect(status() == "error" && !session.isBusy && pipeline.wavs.isEmpty, "Ошибка устройства использует путь ошибки без автоматического ASR")
    expect(!FileManager.default.fileExists(atPath: recorder.url!.path), "После ошибки устройства выполнена обычная очистка WAV")
}

// Неравные размеры входных блоков должны полностью пройти AVAudioConverter
// и без паузы: её граница не может скрывать потерянный короткий пакет.
do {
    let recorder = TestRecorder()
    let url = Paths.state.appendingPathComponent("uneven-packets.wav")
    recorder.start(microphone: "", deviceUID: "", url: url) { result in try! result.get() }
    recorder.emit(2000); recorder.emit(3000, frames: 800); recorder.emit(-4000)
    var wav: Data?
    recorder.stop(discard: false) { result in wav = try! Data(contentsOf: result.get().url) }
    wait("Контроль неравных PCM-блоков завершён") { wav != nil }
    checkWAV(wav!, Array(repeating: Int16(2000), count: 6400)
        + Array(repeating: Int16(3000), count: 800) + Array(repeating: Int16(-4000), count: 6400))
    try FileManager.default.removeItem(at: url)
}

// Настоящий JSONL transport и FluidSpeechClient, без Core ML-весов. Worker
// сохраняет весь полученный PCM, поэтому исключение B проверяется на обеих
// границах: в файле и в фактически отправленных дочернему процессу данных.
private let helper = Paths.support.appendingPathComponent("fake-asr.py")
try #"""
#!/usr/bin/env python3
import base64, json, pathlib, struct, sys, wave
directory = pathlib.Path(sys.argv[2])
directory.mkdir(parents=True, exist_ok=True)
active = None
pcm = bytearray()
def emit(event):
    print('RUNVOICE_ASR ' + json.dumps(event, ensure_ascii=False), flush=True)
emit({'event': 'ready'})
for line in sys.stdin:
    command = json.loads(line)
    action = command['action']
    if action == 'transcribe':
        with wave.open(command['path'], 'rb') as audio:
            command['wav_pcm'] = base64.b64encode(audio.readframes(audio.getnframes())).decode()
    if action == 'finish':
        command['stream_pcm'] = base64.b64encode(pcm).decode()
    with (directory / 'commands.jsonl').open('a') as log:
        log.write(json.dumps(command) + '\n')
    if action == 'start':
        active = command['id']
        pcm.clear()
    elif action == 'audio':
        pcm.extend(base64.b64decode(command['pcm']))
        emit({'event':'partial', 'id':active, 'text':'Начало' if len(pcm) < 20000 else 'Начало продолжение'})
    elif action in ['finish', 'transcribe']:
        emit({'event':'final', 'id':command['id'], 'text':'Начало продолжение'})
    elif action == 'testPartial':
        emit({'event':'partial', 'id':command['id'], 'text':'Начало (поздний ответ)'})
    elif action == 'die':
        sys.exit(0)
    elif action == 'cancel':
        active = None
        pcm.clear()
"""#.write(to: helper, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)

private func fluidScenario(_ model: FluidModel, failOnPause: Bool = false) throws {
    let directory = Paths.support.appendingPathComponent("worker-\(UUID().uuidString)")
    let installation = FluidModelStore.directory(for: model)
    try FileManager.default.createDirectory(at: installation, withIntermediateDirectories: true)
    try installation.path.write(to: installation.appendingPathComponent("installed-model"), atomically: true, encoding: .utf8)
    var worker: ASRProcess?
    let client = FluidSpeechClient(makeWorker: { _ in
        let process = ASRProcess(executable: helper, directory: directory)
        worker = process
        return process
    }, isInstalled: { _ in true })
    let recorder = TestRecorder(), pipeline = TestPipeline()
    let saved = settings(model, preview: model == .nemotron)
    let session = DictationSession(runner: pipeline, recorder: recorder, fluid: client, loadSettings: { saved })
    var visible: [String] = []
    session.onTranscript = { visible.append($0) }
    func commands() -> [[String: Any]] {
        guard let text = try? String(contentsOf: directory.appendingPathComponent("commands.jsonl"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
    }
    func pcmSent() -> Data {
        commands().filter { $0["action"] as? String == "audio" }.reduce(into: Data()) { data, row in
            if let value = row["pcm"] as? String, let decoded = Data(base64Encoded: value) { data.append(decoded) }
        }
    }
    try session.toggle()
    let id = session.recordingSessionID!
    wait("Fluid worker готов") { client.ready && !commands().isEmpty }
    recorder.emit(2000)
    if model == .nemotron {
        wait("Потоковая модель получила доступный PCM A и опубликовала первый текст") {
            diagnostic = "Fluid diagnostic: actions=\(commands().map { $0["action"] ?? "?" }) sent=\(pcmSent().count) delivered=\(recorder.delivered.count) healthy=\(client.healthy) visible=\(visible) recording=\(session.isRecording)"
            return !pcmSent().isEmpty && pcmSent().count == recorder.delivered.count && !visible.isEmpty
        }
        diagnostic = ""
    }
    // Этот хвост ещё стоит в processing при нажатии Space.
    recorder.emit(3000, frames: 800)
    pause(session, id)
    if model == .nemotron { wait("Доступный после drain PCM до Space дошёл до Nemotron") { pcmSent().count == recorder.delivered.count } }
    // AVAudioConverter сохраняет недовыданный хвост до следующего input/EOS;
    // после паузы не дописываем тишину и не завершаем его ради этого хвоста.
    let pausedBytes = recorder.delivered.count
    recorder.emit(18_000)
    spin(0.1)
    let forbidden = ["finish", "cancel", "transcribe", "reset"]
    expect(!commands().contains { forbidden.contains($0["action"] as? String ?? "") }, "Пауза не завершает всю Fluid-сессию и не запускает итоговый ASR")
    expect(recorder.delivered.count == pausedBytes, "Разговор B отсутствует в PCM после паузы")
    if failOnPause {
        _ = worker?.send(["action": "die", "id": "test"])
        wait("Сбой FluidAudio обнаружен во время паузы") { !client.healthy }
        expect(!session.isBusy && status() == "error" && pipeline.wavs.isEmpty,
               "Сбой FluidAudio завершает запись ошибкой без перехода на Whisper")
        expect(!session.finishRecording(expectedSessionID: id), "После сбоя завершение старой записи игнорируется")
        session.shutdown()
        return
    } else if model == .nemotron {
        let frozen = visible
        let wireID = commands().first { $0["action"] as? String == "start" }!["id"] as! String
        _ = worker?.send(["action": "testPartial", "id": wireID])
        spin(0.12)
        expect(visible.count > frozen.count && visible.last == "Начало (поздний ответ)", "Дораспознанный partial Nemotron дополняет текст на паузе")
    }
    _ = session.togglePause(expectedSessionID: id)
    wait("Fluid-сессия продолжена") { session.isRecording }
    if model == .nemotron && !failOnPause {
        expect(visible.last == "Начало (поздний ответ)", "После продолжения сохранённый partial возвращается без сброса сессии")
    }
    recorder.emit(-4000)
    finish(session, id, pipeline)
    let expected = Array(repeating: Int16(2000), count: 6400)
        + Array(repeating: Int16(3000), count: 800) + Array(repeating: Int16(-4000), count: 6400)
    checkWAV(pipeline.wavs[0], expected)
    expect(pipeline.transcripts[0] == "Начало продолжение", "Используется финал выбранного FluidAudio")
    if !failOnPause {
        let action = model == .nemotron ? "finish" : "transcribe"
        let terminals = commands().filter { $0["action"] as? String == action }
        expect(terminals.count == 1, "FluidAudio получает ровно одну команду финального ASR")
        let key = model == .nemotron ? "stream_pcm" : "wav_pcm"
        let received = Data(base64Encoded: terminals[0][key] as! String)!
        expect(samples(received) == expected, "FluidAudio получил A+хвост+C без разговора B")
        expect(commands().filter { $0["action"] as? String == "start" }.count == 1, "Pause/resume не начинает новую сессию модели")
    }
    session.shutdown()
}

if FluidModelStore.supported {
    try fluidScenario(.nemotron)
    try fluidScenario(.parakeet)
    try fluidScenario(.parakeet, failOnPause: true)
}

print("OK: \(checks) проверок паузы диктовки, WAV, переходов и завершения")
