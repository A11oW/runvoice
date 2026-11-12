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
    static var responses: [String] = []
    private var work: DispatchWorkItem?

    static var count: Int {
        lock.lock(); defer { lock.unlock() }
        return requests.count
    }

    static func reset(delay: TimeInterval = 0, statuses: [Int] = [], responses: [String] = []) {
        lock.lock(); defer { lock.unlock() }
        requests = []; bodies = []; self.delay = delay; self.statuses = statuses; self.responses = responses
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
        let text = Self.responses.isEmpty ? "Используй Cypress вместо Playwright." : Self.responses.removeFirst()
        Self.lock.unlock()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: status,
                                           httpVersion: "HTTP/1.1", headerFields: nil)!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: try! JSONEncoder().encode(["text": text]))
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
            expect(!frame.intersects(anchor), "HUD не закрывает указатель")
        }
    }
}
let atBottom = HUDPlacement.calculate(size: size, anchor: NSRect(x: 500, y: 10, width: 1, height: 18),
                                     visibleFrame: screens[0])
expect(atBottom.origin.y > 28 && atBottom.growsUpward, "У нижнего края карточка появляется над указателем")
let locked = HUDSessionPosition(anchor: NSRect(x: 600, y: 500, width: 1, height: 18),
                                visibleFrame: screens[0], reservedSize: NSSize(width: 400, height: 176))
let initial = locked.frame(for: NSSize(width: 180, height: 64))
let expanded = locked.frame(for: NSSize(width: 400, height: 176))
expect(initial.midX == expanded.midX && initial.maxY == expanded.maxY,
       "Появление текста сохраняет верхний центр при изменении ширины")
expect(initial.midX == 600.5 && initial.maxY == 490, "Бабл расположен под указателем по центру с отступом 10 pt")
expect(screens[0].contains(expanded), "Для роста карточки заранее оставлено место")
expect(locked.frame(for: initial.size) == initial, "Повторные показы сохраняют снимок позиции")
let above = HUDSessionPosition(anchor: NSRect(x: 600, y: 10, width: 0, height: 0),
                               visibleFrame: screens[0], reservedSize: size)
let smallAbove = above.frame(for: NSSize(width: 180, height: 40))
let largeAbove = above.frame(for: size)
expect(smallAbove.minY == largeAbove.minY && smallAbove.midX == largeAbove.midX,
       "Над указателем карточка сохраняет нижний центр и растёт вверх")
for screen in screens {
    for x in [screen.minX + 1, screen.maxX - 1] {
        let edge = HUDSessionPosition(anchor: NSRect(x: x, y: screen.midY, width: 0, height: 0),
                                      visibleFrame: screen, reservedSize: size)
        let compact = edge.frame(for: NSSize(width: 150, height: 40))
        let full = edge.frame(for: size)
        expect(screen.contains(compact) && screen.contains(full) && compact.midX == full.midX,
               "На краю экрана центр фиксируется с запасом под максимальный размер")
    }
}

let result = DictationState(raw: "done|Используй Cypress | Playwright.\nЕщё строка.")!
expect(result.hud?.text == "Готово", "Заголовок результата отделён от расшифровки")
expect(result.message == "Используй Cypress | Playwright.\nЕщё строка.", "Полный результат сохраняется для вставки и истории")
expect(result.hud?.transcript.isEmpty == true, "Успех без расшифровки в HUD")
expect(result.hud?.autoHideAfter == 1, "Успех скрывается через секунду")
expect(DictationState(raw: "fixing|Сырой текст")?.hud?.transcript.isEmpty == true, "RAW скрыт при постобработке")
expect(DictationState.transcribing.hud?.transcript.isEmpty == true, "Финальный ASR без preview")
expect(DictationState.transcribing.hud?.showSpinner == true && DictationState.fixing(message: "").hud?.showSpinner == true,
       "Финальный ASR и правка используют один спиннер")
expect(DictationState.preparing.hud?.showSpinner == false && DictationState.recording.hud?.showSpinner == false,
       "При подготовке остаётся микрофон, при записи — эквалайзер")
expect(DictationState.done(message: "").hud?.showSpinner == false && DictationState.error(message: "").hud?.showSpinner == false,
       "Спиннер выключается после завершения и ошибки")
for state in [DictationState.done(message: "текст"), .error(message: "ошибка"), .info(message: "отмена"), .idle, .preparing] {
    expect(state.statusItemSymbol == StatusItemSymbol.idle, "Неактивное состояние возвращает исходную иконку")
}
expect(DictationState.recording.statusItemSymbol == StatusItemSymbol.listening, "Иконка слушания только при записи")
expect(DictationState.transcribing.statusItemSymbol == StatusItemSymbol.processing, "Иконка финального ASR")
expect(DictationState.fixing(message: "сырой текст").statusItemSymbol == StatusItemSymbol.processing, "Правка остаётся активным процессом")

// Результат показывает только метаданные итогового текста и реального получателя.
let receiver = HUDApplication(name: "WebStorm", bundleURL: URL(fileURLWithPath: "/Applications/WebStorm.app"))
let receipt = HUDContent.completed(text: "Раз два три, раз два три!", application: receiver)
expect(receipt.delivery?.wordCount == 6 && receipt.displayText == "WebStorm · 6 слов", "Счётчик слов финального текста")
expect(receipt.transcript.isEmpty && receipt.autoHideAfter == 1, "Успех компактен, без расшифровки, на одну секунду")
expect(HUDDelivery(text: "Используй Cypress вместо Playwright.", application: nil).wordCount == 4, "Подсчёт смешанной речи")
expect(HUDDelivery(text: " \n … , 😀 ", application: nil).wordCount == 0, "Пунктуация и emoji не считаются словами")
expect(HUDDelivery.words(1) == "1 слово" && HUDDelivery.words(2) == "2 слова" && HUDDelivery.words(5) == "5 слов", "Склонение счётчика")
expect(HUDDelivery.words(11) == "11 слов" && HUDDelivery.words(14) == "14 слов" && HUDDelivery.words(21) == "21 слово", "Исключения склонения")
let clipboardReceipt = HUDContent.completed(text: "Итоговый текст", application: receiver, pasted: false)
expect(clipboardReceipt.delivery?.application == nil && clipboardReceipt.displayText == "Скопировано · 2 слова", "Без отправки вставки не показывается приложение-получатель")
func receiptWidth(_ text: String, maximum: CGFloat = 360) -> CGFloat {
    let title = NSTextField(labelWithString: text)
    title.font = HUDLayout.titleFont
    return HUDLayout.compactWidth(titleWidth: title.fittingSize.width, showsApplication: true, maximum: maximum)
}
let smallReceipt = receiptWidth("Safari · 1 слово")
let largeReceipt = receiptWidth("Visual Studio Code · 123 слова")
expect(smallReceipt < largeReceipt && largeReceipt < 360, "Ширина успеха соответствует содержимому")
expect(receiptWidth(String(repeating: "длинное имя ", count: 20), maximum: 220) == 220,
       "Длинное название ограничено шириной экрана")

var waveform = WaveformLevels()
var lowBands = [CGFloat](repeating: 0, count: 18); lowBands[3] = 0.8
waveform.update(lowBands)
expect(waveform.levels.count == 18 && waveform.levels[3] == 0.8, "Полоса сохраняет частотную позицию")
var highBands = [CGFloat](repeating: 0, count: 18); highBands[12] = 0.7
waveform.update(highBands)
expect(waveform.levels[3] == 0 && waveform.levels[12] == 0.7, "Новый спектр заменяет старый без прокрутки и следа")
waveform.update([.nan, -1, 10])
expect(Array(waveform.levels.prefix(3)) == [0, 0, 1] && waveform.levels.dropFirst(3).allSatisfy { $0 == 0 },
       "Некорректные/отсутствующие уровни нормализуются без старых полос")
waveform.reset()
expect(waveform.levels.allSatisfy { $0 == 0 }, "В новой диктовке нет волн от предыдущей записи")

// Дефектные гипотезы не должны попадать в HUD и переписывать хороший черновик.
expect(LivePreviewText.clean(" \nИспользуй\t Cypress   вместо Playwright. ") == "Используй Cypress вместо Playwright.", "Пробелы и переносы нормализуются")
expect(LivePreviewText.clean("Текст,,,, ,,,, дальше.... ...") == "Текст, дальше…", "Пунктуационные петли удалены")
expect(LivePreviewText.clean(String(repeating: ", . ", count: 100)) == nil, "Одна пунктуация не является распознанным текстом")
expect(LivePreviewText.clean("[BLANK_AUDIO]") == nil, "Маркер тишины не показывается")
expect(LivePreviewText.clean("C++ и v3.5, file.swift") == "C++ и v3.5, file.swift", "Технические обозначения сохранены")
expect(LivePreviewText.clean("один два три один два три конец") == "один два три конец", "Дублированный фрагмент сокращается")
expect(LivePreviewText.clean("да да, хорошо") == "да да, хорошо", "Обычный короткий повтор сохранён")
expect(LivePreviewText.clean(String(repeating: "ошибка ", count: 80)) == nil, "Зациклившийся декодер не меняет HUD")
var stabilizer = LivePreviewStabilizer()
expect(stabilizer.update("Используй Cypress", windowStart: 0) == "Используй", "Первый отклик ранний")
expect(stabilizer.update("Используй Cypress вместо", windowStart: 0) == "Используй Cypress", "Подтверждение слов по соседним окнам")
expect(stabilizer.update(",,,,,,", windowStart: 0) == nil, "Мусор не сбрасывает подтверждённый текст")
expect(stabilizer.update("Используй Cypress вместо Playwright", windowStart: 0) == "Используй Cypress вместо", "Черновик растёт после мусорного ответа")
expect(stabilizer.update("Cypress вместо Playwright сегодня", windowStart: 19200) == "Используй Cypress вместо Playwright", "Сдвиг окна не дублирует слова")
expect(stabilizer.update("вместо Playwright сегодня", windowStart: 38400, settled: true) == "Используй Cypress вместо Playwright сегодня", "Последний хвост подтверждается на паузе")
expect(stabilizer.update("вместо Playwright сегодня", windowStart: 57600) == nil, "Одинаковая гипотеза не перерисовывается")

for width: CGFloat in [200, 332] {
    let long = (1...60).map { "Строка \($0): Используй Cypress вместо Playwright." }.joined(separator: "\n")
    let snippet = HUDTranscriptLayout.fit(long, width: width, lineCount: 4)
    expect(snippet.lines == 4 && snippet.text.contains("60"), "Показаны последние четыре строки")
    let fittedAgain = HUDTranscriptLayout.fit(snippet.text, width: width, lineCount: 4)
    expect(fittedAgain.text == snippet.text && fittedAgain.lines <= 4, "Обрезка не вызывает новый перенос и скачок")
}
let manyLines = (1...100).map { "Строка \($0): проверяем распознавание и отображение текста." }.joined(separator: "\n")
expect(HUDTranscriptLayout.fit(manyLines, width: 332).lines == 3, "Default preview — три строки")
for count in 1...10 {
    let snippet = HUDTranscriptLayout.fit(manyLines, width: 332, lineCount: count)
    expect(snippet.lines == count, "Выбранный предел строк \(count) поддерживается")
    expect(HUDTranscriptLayout.fit(snippet.text, width: 332, lineCount: count).text == snippet.text,
           "Обрезка по \(count) строкам стабильна")
}
let firstPage = HUDTranscriptLayout.fit(String(repeating: "Подтверждённые слова продолжают строку. ", count: 12), width: 332)
let anchoredPage = HUDTranscriptLayout.fit("Сдвинутое окно " + firstPage.text + " Новые слова", width: 332, keeping: firstPage.text)
let expectedPage = HUDTranscriptLayout.fit(firstPage.text + " Новые слова", width: 332)
expect(anchoredPage.text == expectedPage.text, "Сдвиг начала ASR-окна не переносит видимые строки заново")
expect(HUDTranscriptLayout.fit("", width: 332).lines == 0, "Пустой preview не занимает строки")
expect(!LiveTranscriber.containsSpeech(Data(repeating: 0, count: 32000)), "Новая тишина не вызывает бесконечный ASR")
expect(LiveTranscriber.containsSpeech(Data(repeating: 0x12, count: 32000)), "Речь проходит energy gate")
var acrossPause = LivePreviewStabilizer()
_ = acrossPause.update("Начало записи", windowStart: 0, firstWordOnly: false)
_ = acrossPause.update("Запись продолжается дальше", windowStart: 19200)
expect(acrossPause.update("Тихая пауза завершилась", windowStart: 220000) == nil, "Новый кусок ещё не подтверждён")
expect(acrossPause.update("Тихая пауза завершилась успешно", windowStart: 240000)?.hasPrefix("Начало записи") == true,
       "После разрыва окна предыдущие строки не исчезают целиком")

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

// Нативная запись передаёт PCM напрямую, без опроса файла.
FakeWhisper.reset()
try? fm.removeItem(at: pcmURL)
let memoryCount = texts.count
transcriber.start(modelPath: "/model", language: "auto", vocabulary: ["Cypress", "Playwright"], inMemory: true)
transcriber.append(Data(repeating: 0x12, count: 25_600))
waitFor("Preview из памяти без rec.pcm") { texts.count > memoryCount }
expect(FakeWhisper.bodies.last?.range(of: Data("Cypress, Playwright".utf8)) != nil, "Словарь передаётся в Whisper prompt")
transcriber.stop()
transcriber.append(Data(repeating: 0x12, count: 32_000))
spin(0.08)
expect(FakeWhisper.count == 1, "Поздний PCM после stop игнорируется")

FakeWhisper.reset(responses: ["Начало записи", String(repeating: "повтор ", count: 80),
                               "Начало записи продолжается", "Начало записи продолжается дальше"])
let beforeGlitch = texts.count
transcriber.start(modelPath: "/model", language: "ru", inMemory: true)
transcriber.append(Data(repeating: 0x12, count: 64_000))
waitFor("Первый ответ до дефектной гипотезы") { texts.count > beforeGlitch }
let good = texts.last
transcriber.append(Data(repeating: 0x12, count: 19_200))
waitFor("Ответ с зацикливанием получен") { FakeWhisper.count == 2 }
spin(0.08)
expect(texts.last == good && texts.count == beforeGlitch + 1, "Петля не заменяет последнюю хорошую строку")
transcriber.append(Data(repeating: 0x12, count: 19_200))
waitFor("Восстановление после петли") { FakeWhisper.count == 3 }
spin(0.08)
transcriber.append(Data(repeating: 0x12, count: 19_200))
waitFor("Подтверждённая речь снова растёт") { texts.last == "Начало записи продолжается" }
transcriber.stop()

FakeWhisper.reset()
transcriber.start(modelPath: "/model", language: "ru", inMemory: true)
transcriber.append(Data(repeating: 0x12, count: 25_600))
waitFor("Речь перед паузой") { FakeWhisper.count == 1 }
spin(0.08)
transcriber.append(Data(repeating: 0, count: 19_200))
waitFor("Одно подтверждение хвоста на паузе") { FakeWhisper.count == 2 }
spin(0.08)
transcriber.append(Data(repeating: 0, count: 192_000))
spin(0.12)
expect(FakeWhisper.count == 2, "Длинная тишина не порождает повторные запросы и пунктуацию")
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
let notSent = delivery.deliver("Без разрешения", restoreClipboard: true) { false }
expect(!notSent, "Невозможность отправить вставку передаётся в результат HUD")
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
    let expectedSuffix = ProcessInfo.processInfo.environment["RUNVOICE_TEST_EXPECT_SUFFIX"]
    var trace: [String] = []
    let started = ProcessInfo.processInfo.systemUptime
    var feeder: Timer?
    let file = streaming ? try FileHandle(forWritingTo: pcmURL) : nil
    defer { feeder?.invalidate(); try? file?.close() }
    if streaming {
        var offset = 0
        // Микрофон продолжает отдавать маленькие пакеты тишины во время паузы.
        // Один большой скачок файла не воспроизводит подтверждение хвоста.
        let audioWithPause = inputPCM + Data(repeating: 0, count: 64_000)
        feeder = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            guard offset < audioWithPause.count else {
                feeder?.invalidate()
                return
            }
            let end = min(audioWithPause.count, offset + 1600)
            try? file?.write(contentsOf: audioWithPause.subdata(in: offset..<end))
            offset = end
        }
    }
    live.onUpdate = {
        trace.append($0)
        transcript = $0
        if firstResult == nil { firstResult = ($0, Int((ProcessInfo.processInfo.systemUptime - started) * 1000)) }
    }
    live.start(modelPath: "/integration-model",
               language: ProcessInfo.processInfo.environment["RUNVOICE_TEST_LANGUAGE"] ?? "en",
               vocabulary: (ProcessInfo.processInfo.environment["RUNVOICE_TEST_VOCAB"] ?? "").components(separatedBy: ","))
    let end = Date().addingTimeInterval(max(35, Double(inputPCM.count) / 32_000 + 12))
    func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }
    func complete() -> Bool {
        guard let transcript else { return false }
        if let expectedSuffix { return Array(words(transcript).suffix(words(expectedSuffix).count)) == words(expectedSuffix) }
        return expected.map { words($0) == words(transcript) } ?? true
    }
    while !complete(), Date() < end { spin(0.05) }
    live.stop()
    feeder?.invalidate()
    if ProcessInfo.processInfo.environment["RUNVOICE_TEST_TRACE"] == "1",
       let data = try? JSONEncoder().encode(trace) {
        FileHandle.standardOutput.write(Data("Preview trace: ".utf8) + data + Data([10]))
    }
    expect(transcript?.isEmpty == false, "Реальный Whisper вернул предварительный текст до остановки")
    expect(complete(), "Полный фрагмент распознан без потери слов")
    print("Whisper integration OK: first=\(firstResult!.milliseconds) ms, first text=\(firstResult!.text), complete=\(transcript!)")
}
