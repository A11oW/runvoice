import AppKit
import Foundation

private var checks = 0
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    guard condition() else { fatalError("FAIL: " + message) }
}

private func spin(_ seconds: TimeInterval) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
}

private func waitFor(_ message: String, _ condition: () -> Bool) {
    let end = Date().addingTimeInterval(2)
    while !condition(), Date() < end { spin(0.01) }
    expect(condition(), message)
}

private final class FakeWhisper: URLProtocol {
    static let lock = NSLock()
    static var requests: [URLRequest] = []
    static var bodies: [Data] = []
    static var delay: TimeInterval = 0
    static var statuses: [Int] = []
    private var work: DispatchWorkItem?

    static var count: Int {
        lock.lock(); defer { lock.unlock() }
        return requests.count
    }

    static func reset(delay: TimeInterval = 0, statuses: [Int] = []) {
        lock.lock(); defer { lock.unlock() }
        requests = []; bodies = []; self.delay = delay; self.statuses = statuses
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        Self.lock.lock()
        Self.requests.append(request)
        Self.bodies.append(body)
        let delay = Self.delay
        let status = Self.statuses.isEmpty ? 200 : Self.statuses.removeFirst()
        Self.lock.unlock()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: status,
                                           httpVersion: "HTTP/1.1", headerFields: nil)!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data("{\"text\":\"Используй Cypress вместо Playwright.\"}".utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
        self.work = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    override func stopLoading() { work?.cancel() }
}

let fm = FileManager.default
let directory = fm.temporaryDirectory.appendingPathComponent("runvoice-live-tests-" + UUID().uuidString)
try fm.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: directory) }
let pcmURL = directory.appendingPathComponent("rec.pcm")
let markerURL = directory.appendingPathComponent("whisper-server.model")

// Заголовок WAV, растущий/нечётный PCM и ограничение длительности предпросмотра.
let pcm = Data((0..<512_001).map { UInt8($0 % 251) })
try pcm.write(to: pcmURL)
let preview = LiveTranscriber.readPreview(from: pcmURL)!
expect(preview.byteCount == 512_000, "PCM выравнивается по 16-битным отсчётам")
expect(preview.wav.count == 44 + 192_000, "В preview не больше 6 секунд")
expect(preview.wav.suffix(192_000) == pcm.subdata(in: 320_000..<512_000), "Читается хвост снимка PCM")
expect(String(data: preview.wav.prefix(4), encoding: .ascii) == "RIFF", "RIFF header")
expect(Array(preview.wav[24..<28]) == [0x80, 0x3e, 0, 0], "WAV: 16000 Hz LE")
expect(Array(preview.wav[40..<44]) == [0, 0xee, 2, 0], "WAV: длина data = 192000")
try Data(repeating: 0x12, count: 25_600).write(to: pcmURL)
expect(LiveTranscriber.readPreview(from: pcmURL) != nil, "Достаточно 0.8 с для первого preview")
expect(LiveTranscriber.readPreview(from: pcmURL, afterByteCount: 25_600) == nil, "Без нового звука PCM не перечитывается")
try Data(repeating: 0, count: 6_400).write(to: pcmURL)
expect(LiveTranscriber.readPreview(from: pcmURL) == nil, "Нет запросов на слишком короткий звук")
expect(LiveTranscriber.readPreview(from: directory.appendingPathComponent("missing")) == nil, "Нет падения без PCM")

// Геометрия в центре, у всех краёв, на экранах с отрицательными координатами.
let size = NSSize(width: 400, height: 160)
let screens = [NSRect(x: 0, y: 0, width: 1440, height: 900),
               NSRect(x: -1920, y: 150, width: 1920, height: 1080),
               NSRect(x: 0, y: -1080, width: 1920, height: 1080)]
for screen in screens {
    for x in [screen.minX + 1, screen.midX, screen.maxX - 1] {
        for y in [screen.minY + 1, screen.midY, screen.maxY - 20] {
            let anchor = NSRect(x: x, y: y, width: 1, height: 18)
            let placement = HUDPlacement.calculate(size: size, anchor: anchor, visibleFrame: screen)
            let frame = NSRect(origin: placement.origin, size: size)
            expect(screen.contains(frame), "HUD целиком на экране \(screen) / \(anchor)")
            expect(!frame.intersects(anchor), "HUD не закрывает каретку")
        }
    }
}
let atBottom = HUDPlacement.calculate(size: size, anchor: NSRect(x: 500, y: 10, width: 1, height: 18),
                                     visibleFrame: screens[0])
expect(atBottom.origin.y > 28, "У нижнего края карточка появляется над кареткой")
let locked = HUDSessionPosition(anchor: NSRect(x: 600, y: 500, width: 1, height: 18),
                                visibleFrame: screens[0], reservedSize: NSSize(width: 400, height: 176))
let initial = locked.frame(for: NSSize(width: 400, height: 64))
let expanded = locked.frame(for: NSSize(width: 400, height: 176))
expect(initial.minX == expanded.minX && initial.maxY == expanded.maxY,
       "Появление текста не перемещает верхний левый угол")
expect(screens[0].contains(expanded), "Для роста карточки заранее оставлено место")
expect(locked.frame(for: initial.size) == initial, "Повторные показы сохраняют снимок позиции")

let result = DictationState(raw: "done|Используй Cypress | Playwright.\nЕщё строка.")!
expect(result.hud?.text == "Готово", "Заголовок результата отделён от расшифровки")
expect(result.hud?.transcript == "Используй Cypress | Playwright.\nЕщё строка.", "Разделители и переносы сохраняются")
expect(result.hud?.autoHideAfter == 5, "Результат с текстом виден 5 секунд")
expect(DictationState(raw: "fixing|Сырой текст")?.hud?.transcript == "Сырой текст", "RAW виден при постобработке")

let configuration = URLSessionConfiguration.ephemeral
configuration.protocolClasses = [FakeWhisper.self]
let session = URLSession(configuration: configuration)
defer { session.invalidateAndCancel() }
let transcriber = LiveTranscriber(directory: directory,
                                  serverURL: URL(string: "http://127.0.0.1:8799")!,
                                  session: session, interval: 0.04)
var texts: [String] = []
var warmups = 0
transcriber.onUpdate = { texts.append($0) }
transcriber.onNeedsServer = { warmups += 1 }
try Data(repeating: 0x12, count: 64_000).write(to: pcmURL)

// Чужой сервер: нет совпадающего маркера — аудио не отправляется.
FakeWhisper.reset()
try "/other-model|/server".write(to: markerURL, atomically: true, encoding: .utf8)
transcriber.start(modelPath: "/model", language: "ru")
spin(0.16)
expect(FakeWhisper.count == 0, "Не отправляем аудио чужому серверу")
expect(warmups == 1, "Прогрев не запускается каждый тик")
transcriber.stop()

// Один запрос в полёте, затем повтор только при накоплении нового звука.
try "/model|/server".write(to: markerURL, atomically: true, encoding: .utf8)
FakeWhisper.reset(delay: 0.25)
transcriber.start(modelPath: "/model", language: "auto")
waitFor("Начался preview-запрос") { FakeWhisper.count == 1 }
spin(0.13)
expect(FakeWhisper.count == 1, "Preview-запросы не выполняются одновременно")
waitFor("Текст пришёл до остановки записи") { texts.count == 1 }
spin(0.12)
expect(FakeWhisper.count == 1, "Повторно не распознаём тот же звук")
FakeWhisper.lock.lock()
let body = String(decoding: FakeWhisper.bodies[0], as: UTF8.self)
FakeWhisper.lock.unlock()
expect(body.contains("\r\n\r\nauto\r\n"), "Язык передаётся в preview")
expect(body.contains("filename=\"preview.wav\""), "Аудио передаётся multipart WAV")
expect(body.contains("name=\"audio_ctx\"\r\n\r\n512\r\n"), "Preview использует короткий контекст")
expect(body.contains("name=\"no_timestamps\"\r\n\r\ntrue\r\n"), "Preview не вычисляет ненужные метки")
FakeWhisper.lock.lock()
let connection = FakeWhisper.requests[0].value(forHTTPHeaderField: "Connection")
FakeWhisper.lock.unlock()
expect(connection == "close", "Отмена preview закрывает HTTP-соединение")
try Data(repeating: 0x34, count: 96_000).write(to: pcmURL)
waitFor("Новый звук запускает следующий запрос") { FakeWhisper.count == 2 }
transcriber.stop()
spin(0.35)
expect(texts.count == 1, "После остановки запоздалый ответ не меняет HUD")

// Новая сессия не наследует счётчик/текст предыдущей; HTTP-ошибка не убивает preview.
FakeWhisper.reset(statuses: [503, 200])
transcriber.start(modelPath: "/model", language: "en")
waitFor("После ошибки предпросмотр возобновился") { texts.count == 2 }
expect(FakeWhisper.count == 2, "После HTTP-ошибки есть повторная попытка")
transcriber.stop()

FakeWhisper.reset()
try Data(repeating: 0x12, count: 25_600).write(to: pcmURL)
let previousCount = texts.count
transcriber.start(modelPath: "/model", language: "ru")
waitFor("Короткий фрагмент даёт ранний текст") { texts.count == previousCount + 1 }
expect(texts.last == "Используй", "Первый короткий ответ не показывает достроенный конец фразы")
transcriber.stop()

// Изолированный pasteboard: общий пользовательский буфер не используется.
let pasteboard = NSPasteboard.withUniqueName()
defer { pasteboard.releaseGlobally() }
pasteboard.setString("До диктовки", forType: .string)
let delivery = DictationPasteboard(pasteboard: pasteboard, restoreDelay: 0.04)
var pasted: [String] = []
delivery.deliver("Итоговый текст", restoreClipboard: true) {
    pasted.append(pasteboard.string(forType: .string) ?? "")
    return true
}
expect(pasted == ["Итоговый текст"], "Буфер заполнен до отправки ⌘V, одна вставка")
spin(0.08)
expect(pasteboard.string(forType: .string) == "До диктовки", "Буфер восстановлен после вставки")
delivery.deliver("Другой текст", restoreClipboard: true) { true }
pasteboard.clearContents()
pasteboard.setString("Пользователь скопировал новое", forType: .string)
spin(0.08)
expect(pasteboard.string(forType: .string) == "Пользователь скопировал новое", "Восстановление не затирает новое копирование")
delivery.deliver("Без разрешения", restoreClipboard: true) { false }
spin(0.08)
expect(pasteboard.string(forType: .string) == "Без разрешения", "Без Accessibility текст остаётся для ручной вставки")
delivery.deliver("Оставить в буфере", restoreClipboard: false) { true }
spin(0.08)
expect(pasteboard.string(forType: .string) == "Оставить в буфере", "Выключенное восстановление учитывается")

print("OK: \(checks) проверок live preview, состояний и размещения HUD")

// Необязательная интеграция с отдельным настоящим whisper-server и синтетической речью.
if let input = ProcessInfo.processInfo.environment["RUNVOICE_TEST_PCM"],
   let address = ProcessInfo.processInfo.environment["RUNVOICE_TEST_SERVER"],
   let url = URL(string: address) {
    let inputPCM = try Data(contentsOf: URL(fileURLWithPath: input))
    let streaming = ProcessInfo.processInfo.environment["RUNVOICE_TEST_STREAM"] == "1"
    try (streaming ? Data() : inputPCM).write(to: pcmURL)
    try "/integration-model|test-server".write(to: markerURL, atomically: true, encoding: .utf8)
    let live = LiveTranscriber(directory: directory, serverURL: url)
    var transcript: String?
    var firstResult: (text: String, milliseconds: Int)?
    let expected = ProcessInfo.processInfo.environment["RUNVOICE_TEST_EXPECT"]
    let started = ProcessInfo.processInfo.systemUptime
    var feeder: Timer?
    let file = streaming ? try FileHandle(forWritingTo: pcmURL) : nil
    defer { feeder?.invalidate(); try? file?.close() }
    if streaming {
        var offset = 0
        feeder = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            guard offset < inputPCM.count else {
                // Как при паузе перед стопом: даём распознать конец последнего слова.
                try? file?.write(contentsOf: Data(repeating: 0, count: 32_000))
                feeder?.invalidate()
                return
            }
            let end = min(inputPCM.count, offset + 1600)
            try? file?.write(contentsOf: inputPCM.subdata(in: offset..<end))
            offset = end
        }
    }
    live.onUpdate = {
        transcript = $0
        if firstResult == nil { firstResult = ($0, Int((ProcessInfo.processInfo.systemUptime - started) * 1000)) }
    }
    live.start(modelPath: "/integration-model",
               language: ProcessInfo.processInfo.environment["RUNVOICE_TEST_LANGUAGE"] ?? "en")
    let end = Date().addingTimeInterval(35)
    func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }
    func complete() -> Bool {
        guard let transcript else { return false }
        return expected.map { words($0) == words(transcript) } ?? true
    }
    while !complete(), Date() < end { spin(0.05) }
    live.stop()
    feeder?.invalidate()
    expect(transcript?.isEmpty == false, "Реальный Whisper вернул предварительный текст до остановки")
    expect(complete(), "Полный фрагмент распознан без потери слов")
    print("Whisper integration OK: first=\(firstResult!.milliseconds) ms, first text=\(firstResult!.text), complete=\(transcript!)")
}
