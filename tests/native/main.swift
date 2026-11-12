import Foundation
import AVFoundation

var checks = 0
func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    precondition(value(), message)
}
func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }

testDictationKeyPolicy()
testEscapeToCancel()

func tonePCM(_ frequency: Double, count: Int = AudioSpectrumAnalyzer.frameSize) -> Data {
    var data = Data()
    for index in 0..<count {
        var sample = Int16(sin(2 * Double.pi * frequency * Double(index) / 16_000) * 20_000).littleEndian
        withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) }
    }
    return data
}
func peakBand(_ levels: [CGFloat]) -> Int { levels.indices.max { levels[$0] < levels[$1] }! }
let spectrumAnalyzer = AudioSpectrumAnalyzer()
let lowPCM = tonePCM(250)
let lowSpectrum = spectrumAnalyzer.consume(lowPCM)!
let highPCM = tonePCM(2000)
let highSpectrum = spectrumAnalyzer.consume(highPCM)!
expect(lowSpectrum.count == 18 && highSpectrum.count == 18, "Спектр содержит 18 фиксированных частотных полос")
expect(lowSpectrum.allSatisfy { $0.isFinite && (0...1).contains($0) }, "Диапазон амплитуд спектра")
expect(peakBand(lowSpectrum) < 7 && peakBand(highSpectrum) > 10, "Частота меняет высоту нужной полосы, а не сдвигает историю")
expect(lowSpectrum.max()! > 0.6 && highSpectrum.max()! > 0.6, "Спектр реагирует на реальный PCM")
let silencePCM = Data(repeating: 0, count: AudioSpectrumAnalyzer.frameSize * 2)
expect(spectrumAnalyzer.consume(silencePCM)!.allSatisfy { $0 == 0 }, "Тишина сразу заменяет прошлый спектр")
let packetized = AudioSpectrumAnalyzer()
var packetSpectrum: [CGFloat]?
for offset in stride(from: 0, to: lowPCM.count, by: 128) {
    packetSpectrum = packetized.consume(lowPCM.subdata(in: offset..<min(offset + 128, lowPCM.count))) ?? packetSpectrum
}
expect(zip(packetSpectrum!, lowSpectrum).allSatisfy { abs($0 - $1) < 0.00001 }, "Разбиение PCM на пакеты не меняет спектр")
let latestSpectrum = spectrumAnalyzer.consume(lowPCM + highPCM)!
expect(peakBand(latestSpectrum) == peakBand(highSpectrum), "Из большого пакета показывается последний полный кадр")
let incomplete = AudioSpectrumAnalyzer()
expect(incomplete.consume(lowPCM.prefix(512)) == nil, "Неполный кадр не публикуется")
incomplete.reset()
expect(incomplete.consume(silencePCM)!.allSatisfy { $0 == 0 }, "Сброс не переносит PCM предыдущей сессии")

let terms = SpeechVocabulary.normalize([" Cypress ", "cypress", "Playwright\nGitHub Actions", "", "Кириллица"])
expect(terms == ["Cypress", "Playwright", "GitHub Actions", "Кириллица"], "Нормализация и дедупликация словаря")
expect(SpeechVocabulary.normalize((0..<100).map { "word\($0)" }).count == 64, "Ограничение размера словаря")
expect(SpeechVocabulary.prompt(Array(repeating: String(repeating: "я", count: 79), count: 100)).utf8.count <= 800, "Лимит UTF-8")
let legacy = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
expect(legacy.recognitionEngine == "whisper" && legacy.speechVocabulary.isEmpty, "Миграция не переключает движок")
expect(legacy.microphoneUID.isEmpty, "Микрофон старого формата мигрирует по имени")
expect(legacy.previewEnabled && legacy.previewLineCount == 3, "Старые настройки получают включённый preview на 3 строки")
expect(!legacy.stopRecordingOnEnter && !Settings().stopRecordingOnEnter, "Завершение по Enter выключено в новых и старых настройках")
expect(!legacy.cancelRecordingOnEscape && !Settings().cancelRecordingOnEscape, "Отмена по Esc выключена в новых и старых настройках")
let enabledEnter = try JSONDecoder().decode(Settings.self, from: Data("{\"stopRecordingOnEnter\":true}".utf8))
expect(enabledEnter.stopRecordingOnEnter, "Включение Enter загружается из настроек")
let enterRoundTrip = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(enabledEnter))
expect(enterRoundTrip.stopRecordingOnEnter, "Выбор Enter сохраняется при повторном чтении")
let disabledPreview = try JSONDecoder().decode(Settings.self, from: Data("{\"previewEnabled\":false,\"previewLineCount\":10}".utf8))
expect(!disabledPreview.showsRecognitionPreview && disabledPreview.previewLineCount == 10, "Отключение preview не сбрасывает число строк")
let lowPreview = try JSONDecoder().decode(Settings.self, from: Data("{\"previewLineCount\":0}".utf8))
let highPreview = try JSONDecoder().decode(Settings.self, from: Data("{\"previewLineCount\":100}".utf8))
expect(lowPreview.previewLineCount == 1 && highPreview.previewLineCount == 10, "Число строк ограничено 1–10 при загрузке")
let unknown = try JSONDecoder().decode(Settings.self, from: Data("{\"recognitionEngine\":\"unknown\"}".utf8))
expect(unknown.recognitionEngine == "whisper", "Неизвестный движок использует Whisper")
var settings = legacy
settings.recognitionEngine = "nemotron"; settings.speechVocabulary = terms
settings.microphoneUID = "stable-input-uid"
settings.previewEnabled = false
settings.previewLineCount = 7
let roundTrip = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
expect(roundTrip == settings, "Сохранение новых настроек")
let legacyHUD = try JSONDecoder().decode(Settings.self, from: Data("{\"showHUD\":false,\"stopRecordingOnEnter\":true,\"cancelRecordingOnEscape\":true,\"language\":\"auto\",\"speechVocabulary\":[\"Cypress\",\"GitHub Actions\"]}".utf8))
expect(legacyHUD.showsRecognitionPreview, "Старая настройка отключения HUD больше не скрывает preview")
let migrated = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacyHUD)) as! [String: Any]
expect(migrated["showHUD"] == nil, "Удалённая настройка не возвращается при сохранении")
let migratedSettings = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(legacyHUD))
expect(migratedSettings == legacyHUD && migratedSettings.cancelRecordingOnEscape && migratedSettings.stopRecordingOnEnter,
       "Миграция сохраняет Enter, Esc, язык и словарь")
let bulkTerms = try SpeechVocabulary.validate(SpeechVocabulary.splitList(" Cypress, cypress\nGitHub Actions\r\nPlaywright, ")).get()
expect(bulkTerms == ["Cypress", "GitHub Actions", "Playwright"], "Массовый ввод сохраняет фразы, порядок и первое написание")
expect((try? SpeechVocabulary.validate([String(repeating: "я", count: 81)]).get()) == nil, "Длинный термин отклоняется без обрезки")
expect((try? SpeechVocabulary.validate((0..<65).map { "term\($0)" }).get()) == nil, "Переполнение словаря отклоняется целиком")

let inputA = AudioInputDevice(id: 11, uid: "builtin", name: "Микрофон MacBook Pro", hardwareName: "MacBook Pro Microphone")
let inputB = AudioInputDevice(id: 22, uid: "usb", name: "USB Microphone", hardwareName: "USB Microphone")
expect(AudioInputDevice.match(name: inputA.name, uid: "", in: [inputA, inputB]) == inputA, "Локализованное имя связывается с UID")
expect(AudioInputDevice.match(name: inputA.hardwareName, uid: "", in: [inputA]) == inputA, "Прежнее имя Core Audio поддерживается")
expect(AudioInputDevice.match(name: "Другое имя", uid: "builtin", in: [inputA]) == inputA, "Смена языка не меняет выбранное устройство")
expect(AudioInputDevice.match(name: inputA.name, uid: "removed", in: [inputA, inputB]) == nil, "Пропавший UID не заменяется другим микрофоном")
expect(NativeAudioRecorder.configurationAction(devicePresent: true, formatMatches: true, running: true) == .ignore, "Служебное уведомление не отменяет работающий capture")
expect(NativeAudioRecorder.configurationAction(devicePresent: true, formatMatches: true, running: false) == .resume, "Остановленный engine с тем же форматом возобновляется")
expect(NativeAudioRecorder.configurationAction(devicePresent: false, formatMatches: true, running: true) == .fail, "Отключение устройства — реальная ошибка")
expect(NativeAudioRecorder.configurationAction(devicePresent: true, formatMatches: false, running: false) == .fail, "Смена формата требует нового converter")

let directory = FileManager.default.temporaryDirectory.appendingPathComponent("runvoice-native-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
let converter = AVAudioConverter(from: source, to: target)!
converter.downmix = true
var chunks = Data()
var levels: [CGFloat] = []
var failures = 0
let url = directory.appendingPathComponent("capture.wav")
let sink = try PCMSink(url: url, converter: converter, output: target,
                       onAudio: { chunks.append($0) }, onLevel: { levels.append($0) }, onFailure: { _ in failures += 1 })
var offset = 0
while offset < 96_000 {
    let count = min(1024, 96_000 - offset)
    let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(count))!
    buffer.frameLength = AVAudioFrameCount(count)
    for channel in 0..<2 {
        for i in 0..<count {
            buffer.floatChannelData![channel][i] = sin(Float(offset + i) * 2 * .pi * 440 / 48_000) * 0.5
        }
    }
    sink.consume(buffer)
    offset += count
}
let recording = try sink.finish()
spin()
let wav = try Data(contentsOf: url)
func u32(_ offset: Int) -> UInt32 { wav.subdata(in: offset..<(offset+4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian } }
expect(abs(Int(recording.frames) - 32_000) <= 64, "Ресемплинг 48k stereo → 16k mono сохраняет длительность")
expect(u32(24) == 16_000 && u32(28) == 32_000, "Корректный WAV-формат")
expect(Int(u32(4)) + 8 == wav.count && Int(u32(40)) + 44 == wav.count, "Заголовок финализирован после stop")
expect(Data(wav.dropFirst(44)) == chunks, "ASR получает тот же PCM, что резервная запись")
expect(!levels.isEmpty && levels.allSatisfy { (0...1).contains($0) }, "Уровень из того же аудиопотока")
expect(failures == 0, "Конвертация не теряет буферы")
let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
expect(permissions?.intValue == 0o600, "Приватная аудиозапись")
expect(NativeAudioRecorder.device(named: "Runvoice nonexistent device 79463") == nil, "Пропавший микрофон не заменяется системным")
let failedURL = directory.appendingPathComponent("failed.wav")
let failed = try PCMSink(url: failedURL, converter: AVAudioConverter(from: source, to: target)!, output: target,
                        onAudio: nil, onLevel: nil, onFailure: nil)
failed.fail(NativeAudioRecorder.Failure.overflow)
do { _ = try failed.finish(); fatalError("Повреждённая запись не должна передаваться ASR") } catch { checks += 1 }
expect(!FileManager.default.fileExists(atPath: failedURL.path), "Ошибка очереди удаляет повреждённый WAV")

// Отдельный настоящий процесс имитирует обрыв/задержку IPC, без модели и сети.
let helper = directory.appendingPathComponent("fake-asr")
try """
#!/usr/bin/env python3
import sys, json
def emit(value):
    print('RUNVOICE_ASR ' + json.dumps(value), flush=True)
print('SDK diagnostic line', flush=True)
emit({'event': 'ready'})
language = ''
for line in sys.stdin:
    c = json.loads(line)
    if c['action'] == 'start':
        language = c['language']
    if c['action'] == 'audio':
        if language == 'crash':
            sys.exit(2)
        emit({'event': 'partial', 'id': 'stale-generation', 'text': 'OLD'})
        emit({'event': 'partial', 'id': c['id'], 'text': 'Cypress'})
    if c['action'] == 'finish' and language != 'timeout':
        emit({'event': 'final', 'id': c['id'], 'text': 'Используй Cypress'})
""".write(to: helper, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
let client = FluidSpeechClient(makeWorker: { ASRProcess(executable: helper, directory: directory) },
                               isInstalled: { true }, finishDeadline: 0.4)
func waitUntil(_ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(3)
    while !condition(), Date() < deadline { spin() }
    expect(condition(), "IPC завершает запрос вовремя")
}
var partials: [String] = []
var failureCount = 0
client.onPartial = { partials.append($0) }
client.onFailure = { failureCount += 1 }
client.start(language: "ru", vocabulary: ["Cypress"])
client.append(Data([0, 0]))
waitUntil { !partials.isEmpty }
expect(partials == ["Cypress"], "Диагностика и partial от старой сессии игнорируются")
var final: String?
client.finish { final = $0 }
waitUntil { final != nil }
expect(final == "Используй Cypress", "IPC возвращает полный финальный текст")
client.start(language: "timeout")
var timeoutReturned = false
client.finish { expect($0 == nil, "Таймаут требует полного резервного ASR"); timeoutReturned = true }
waitUntil { timeoutReturned }
expect(!client.healthy && failureCount == 1, "Таймаут выгружает зависший процесс")
client.start(language: "crash")
client.append(Data([0, 0]))
waitUntil { failureCount == 2 }
var fallbackReturned = false
client.finish { expect($0 == nil, "Падение помощника требует полного резервного ASR"); fallbackReturned = true }
expect(fallbackReturned, "Падение не задерживает финализацию")
client.start(language: "ru")
expect(client.healthy, "Следующая диктовка запускает новый процесс")
client.cancel()
client.unload()
print("OK: \(checks) проверок нативного аудиотракта, словаря и миграции")
