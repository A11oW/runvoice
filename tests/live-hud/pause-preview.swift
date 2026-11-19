import Foundation

private final class PausedPreviewHTTP: URLProtocol {
    static let lock = NSLock()
    static var requests = 0
    static var cancellations = 0
    private var work: DispatchWorkItem?

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        requests = 0; cancellations = 0
    }
    static var counts: (requests: Int, cancellations: Int) {
        lock.lock(); defer { lock.unlock() }
        return (requests, cancellations)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests += 1; Self.lock.unlock()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: 200,
                                           httpVersion: "HTTP/1.1", headerFields: nil)!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data("{\"text\":\"Первый HTTP текст\"}".utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
        self.work = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }
    override func stopLoading() {
        work?.cancel()
        Self.lock.lock(); Self.cancellations += 1; Self.lock.unlock()
    }
}

/// Изолированный тест паузы: локальные callbacks и URLProtocol, без микрофона/сети.
func testPausedPreview() throws {
    var checks = 0
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        precondition(condition(), message)
    }
    func spin(_ duration: TimeInterval) {
        let end = Date().addingTimeInterval(duration)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    }
    func waitFor(_ message: String, _ condition: () -> Bool) {
        let end = Date().addingTimeInterval(2)
        while !condition(), Date() < end { spin(0.005) }
        expect(condition(), message)
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("runvoice-pause-preview-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let preview = LiveTranscriber(directory: directory, serverURL: URL(string: "http://127.0.0.1:1")!, interval: 0.005)
    var requests: [Data] = []
    var replies: [(Result<String, Error>) -> Void] = []
    var cancelled = 0
    var texts: [String] = []
    var warmups = 0
    let recognizer: LiveTranscriber.Recognizer = { pcm, callback in
        requests.append(pcm); replies.append(callback)
        return { cancelled += 1 }
    }
    preview.onUpdate = { texts.append($0) }
    preview.onNeedsServer = { warmups += 1 }
    preview.pause(); preview.resume()
    expect(!preview.isPaused && requests.isEmpty, "Неактивный preview не возобновляется")
    preview.start(modelPath: "parakeet", language: "auto", inMemory: true, recognizer: recognizer)
    let firstPCM = Data(repeating: 0x12, count: 57_600)
    preview.append(firstPCM)
    waitFor("Исходный локальный запрос") { requests.count == 1 }
    replies[0](.success("Сохрани начало записи"))
    waitFor("Подтверждённый текст до паузы") { texts.last == "Сохрани начало записи" }
    let nextPCM = Data(repeating: 0x34, count: 19_200)
    preview.append(nextPCM)
    waitFor("Незавершённый запрос перед паузой") { requests.count == 2 }
    let cancelledReply = replies[1]
    preview.pause(); preview.pause()
    expect(preview.isPaused && cancelled == 1, "Пауза один раз отменяет текущий локальный запрос")
    let drainingPCM = Data(repeating: 0x56, count: 8_000)
    preview.append(drainingPCM)
    cancelledReply(.success("Чужой поздний ответ"))
    spin(0.06)
    expect(requests.count == 2 && texts == ["Сохрани начало записи"], "На паузе нет запросов и поздних публикаций")
    expect(warmups == 0, "Локальная пауза не прогревает Whisper")
    preview.resume(); preview.resume()
    expect(!preview.isPaused && requests.count == 3, "Продолжение сразу отправляет один ожидающий снимок")
    expect(requests[2] == firstPCM + nextPCM + drainingPCM, "Пауза сохраняет весь PCM, включая дренированный хвост")
    cancelledReply(.success("Старый ответ после продолжения"))
    spin(0.02)
    expect(texts == ["Сохрани начало записи"] && requests.count == 3, "Отменённый callback не меняет текущий запрос")
    replies[2](.success("Сохрани начало записи продолжение диктовки"))
    spin(0.02)
    preview.append(nextPCM)
    waitFor("Подтверждающий запрос после продолжения") { requests.count == 4 }
    replies[3](.success("Сохрани начало записи продолжение диктовки"))
    waitFor("Стабилизатор продолжает прежний текст") { texts.last == "Сохрани начало записи продолжение диктовки" }
    expect(texts.filter { $0 == "Сохрани начало записи" }.count == 1, "Начало не публикуется повторно после паузы")
    preview.pause(); preview.resume()
    spin(0.03)
    expect(requests.count == 4, "Продолжение без нового PCM не повторяет уже обработанный запрос")

    preview.append(nextPCM)
    waitFor("Запрос перед остановкой на паузе") { requests.count == 5 }
    let stoppedReply = replies[4]
    preview.pause()
    expect(cancelled == 2, "Следующая пауза отменяет только свой запрос")
    preview.stop(); preview.resume(); preview.append(firstPCM)
    spin(0.02)
    expect(!preview.isPaused && requests.count == 5, "stop завершает паузу и запрещает append/resume")
    preview.start(modelPath: "parakeet", language: "en", inMemory: true, recognizer: recognizer)
    preview.append(Data(repeating: 0x12, count: 25_600))
    waitFor("Новая сессия после остановки на паузе") { requests.count == 6 }
    stoppedReply(.success("Слова прежней сессии"))
    replies[5](.success("Новое начало"))
    waitFor("Новая сессия не наследует стабилизатор") { texts.last == "Новое" }
    preview.stop()

    PausedPreviewHTTP.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PausedPreviewHTTP.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    try "pause-model|server".write(to: directory.appendingPathComponent("whisper-server.model"), atomically: true, encoding: .utf8)
    let http = LiveTranscriber(directory: directory, serverURL: URL(string: "http://127.0.0.1:1")!, session: session, interval: 0.005)
    var httpTexts: [String] = []
    http.onUpdate = { httpTexts.append($0) }
    http.start(modelPath: "pause-model", language: "ru", inMemory: true)
    http.append(firstPCM)
    waitFor("HTTP-запрос перед паузой") { PausedPreviewHTTP.counts.requests == 1 }
    http.pause()
    waitFor("Пауза закрывает HTTP-запрос") { PausedPreviewHTTP.counts.cancellations == 1 }
    http.append(nextPCM)
    spin(0.16)
    expect(httpTexts.isEmpty && PausedPreviewHTTP.counts.requests == 1, "HTTP-preview заморожен на паузе")
    http.resume()
    waitFor("HTTP-preview продолжен") { httpTexts.last == "Первый HTTP текст" }
    expect(PausedPreviewHTTP.counts.requests == 2, "HTTP-продолжение не создаёт очередь запросов")
    http.stop()

    let warming = LiveTranscriber(directory: directory, serverURL: URL(string: "http://127.0.0.1:1")!, interval: 0.005)
    var serverWarmups = 0
    warming.onNeedsServer = { serverWarmups += 1 }
    warming.start(modelPath: "missing-model", language: "ru", inMemory: true)
    expect(serverWarmups == 1, "Начальный прогрев модели")
    warming.pause()
    spin(1.05)
    expect(serverWarmups == 1, "Пауза не запускает повторный прогрев даже после backoff")
    warming.resume()
    expect(serverWarmups == 2, "После продолжения восстановлен обычный прогрев")
    warming.stop()
    // Явное завершение drain публикует весь короткий хвост на паузе.
    let draining = LiveTranscriber(directory: directory, serverURL: URL(string: "http://127.0.0.1:1")!, interval: 0.005)
    var drainRequests: [Data] = []
    var drainReplies: [(Result<String, Error>) -> Void] = []
    var drainedTexts: [String] = []
    draining.onUpdate = { drainedTexts.append($0) }
    draining.start(modelPath: "parakeet", language: "ru", inMemory: true, recognizer: { pcm, callback in
        drainRequests.append(pcm); drainReplies.append(callback)
        return {}
    })
    let shortTail = Data(repeating: 0x12, count: 8000)
    draining.append(shortTail)
    draining.pause()
    draining.finishPausedAudio()
    waitFor("Короткий хвост отправлен без порога 0.6 с") { drainRequests.count == 1 }
    expect(drainRequests[0] == shortTail, "Снимок заканчивается на границе паузы")
    drainReplies[0](.success("Все последние слова"))
    waitFor("Последние слова показаны без продолжения записи") { drainedTexts.last == "Все последние слова" }
    spin(0.03)
    expect(draining.isPaused && drainRequests.count == 1, "После дораспознавания нет периодических запросов")
    draining.stop()

    let full = LiveTranscriber(directory: directory, serverURL: URL(string: "http://127.0.0.1:1")!, interval: 0.005)
    var fullRequests: [Data] = []
    var fullReplies: [(Result<String, Error>) -> Void] = []
    var fullTexts: [String] = []
    full.onUpdate = { fullTexts.append($0) }
    full.start(modelPath: "parakeet", language: "ru", inMemory: true, recognizer: { pcm, callback in
        fullRequests.append(pcm); fullReplies.append(callback)
        return {}
    })
    let recordingPCM = Data(repeating: 0x12, count: 320_000)
    let snapshotURL = directory.appendingPathComponent("paused-capture.wav")
    // Заголовок ещё открытого WAV не содержит настоящую длину payload.
    try (LiveTranscriber.wav(pcm: Data()) + recordingPCM).write(to: snapshotURL)
    full.append(recordingPCM)
    full.pause()
    full.finishPausedAudio(audioURL: snapshotURL)
    // Данные после зафиксированной границы не должны попасть в запрос.
    let writer = try FileHandle(forWritingTo: snapshotURL)
    try writer.seekToEnd()
    try writer.write(contentsOf: shortTail)
    try writer.close()
    waitFor("Полный снимок готов без ограничения 6 с") { fullRequests.count == 1 }
    expect(fullRequests[0] == recordingPCM, "Payload читается до границы паузы без доверия к заголовку WAV")
    fullReplies[0](.success("Раз два три четыре пять шесть семь восемь"))
    waitFor("Полный ответ публикует последние слова на паузе") { fullTexts.last?.hasSuffix("семь восемь") == true }
    full.stop()

    var authoritative = LivePreviewStabilizer()
    _ = authoritative.update("Старая ошибочная привязка", windowStart: 0, firstWordOnly: false)
    expect(authoritative.settleRecording("Раз два три четыре пять шесть") == "Раз два три четыре пять шесть",
           "Полный ответ заменяет ошибочную привязку короткого preview")

    print("OK: \(checks) проверок pause/resume preview")
}
