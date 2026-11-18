import Foundation
import Network
import Darwin

private var checks = 0
private func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !value() { FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8)); exit(1) }
}
private func spin(_ seconds: TimeInterval = 0.02) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
private func wait(_ message: String, _ condition: () -> Bool) {
    let end = Date().addingTimeInterval(8)
    while !condition(), Date() < end { spin() }
    expect(condition(), message)
}
private func port() -> Int {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    var count = socklen_t(MemoryLayout<sockaddr_in>.size)
    withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { value in
            precondition(bind(descriptor, value, count) == 0)
            precondition(getsockname(descriptor, value, &count) == 0)
        }
    }
    return Int(UInt16(bigEndian: address.sin_port))
}
private func body(pcm: Data = Data(repeating: 1, count: 3200), model: String = "runvoice-active") -> Data {
    var data = Data()
    for (key,value) in [("model",model),("response_format","json")] {
        data.append(Data("--fixture\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n".utf8))
    }
    data.append(Data("--fixture\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
    data.append(LiveTranscriber.wav(pcm: pcm)); data.append(Data("\r\n--fixture--\r\n".utf8))
    return data
}
private func request(_ port: Int, path: String = LocalAPIWire.transcriptionPath, method: String = "POST", data: Data? = body()) -> URLRequest {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
    request.httpMethod = method; request.httpBody = data
    if data != nil { request.setValue("multipart/form-data; boundary=fixture", forHTTPHeaderField: "Content-Type") }
    request.timeoutInterval = 10
    return request
}
private let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral; config.httpMaximumConnectionsPerHost = 32
    return URLSession(configuration: config)
}()
private func fetch(_ request: URLRequest) -> (Int, [String: Any]) {
    var answer: (Int, [String: Any])?
    session.dataTask(with: request) { data, response, _ in
        let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        DispatchQueue.main.async { answer = ((response as? HTTPURLResponse)?.statusCode ?? 0, json) }
    }.resume()
    wait("HTTP-запрос завершился") { answer != nil }
    return answer!
}
private final class Backend: APIRecognitionBackend {
    var isReady = false
    var delay: TimeInterval = 0.05
    var calls: [Settings] = []
    var shutdowns = 0
    var fail = false
    private var generation = UUID()
    func prepare(settings: Settings, completion: @escaping (Result<Void, Error>) -> Void) {
        isReady = !fail
        completion(fail ? .failure(LocalAPIError(503,"fixture")) : .success(()))
    }
    func transcribe(pcm: Data, settings: Settings, completion: @escaping (Result<String, Error>) -> Void) {
        calls.append(settings)
        let token = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard self?.generation == token else { return }
            completion(.success("raw:\(settings.recognitionTechnology.rawValue):\(settings.language):\(settings.speechVocabulary.joined(separator: ","))"))
        }
    }
    func shutdown() { isReady = false; shutdowns += 1; generation = UUID() }
}

private final class FilterFixture: APIAudioFiltering {
    var ready = false
    var fail = false
    func prepare(_ completion: @escaping (Result<Void, Error>) -> Void) { ready = true; completion(.success(())) }
    func apply(_ pcm: Data, settings: Settings, completion: @escaping (Result<Data, Error>) -> Void) {
        completion(fail ? .failure(LocalAPIError(503,"fixture")) : .success(Data()))
    }
    func stop() { ready = false }
}

@main struct Tests {
    static func main() throws {
        let defaults = try JSONDecoder().decode(Settings.self, from: Data("{\"providers\":[]}".utf8))
        expect(!defaults.apiEnabled && !defaults.apiImproveText && defaults.apiPort == 8790, "Совместимые настройки API по умолчанию")
        expect(defaults.apiRecognitionModel == .application, "Старые настройки наследуют модель приложения")
        let fixtureDir = Paths.support.appendingPathComponent("api-model-fixtures")
        try FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
        let q5 = fixtureDir.appendingPathComponent("ggml-large-v3-turbo-q5_0.bin")
        let q8 = fixtureDir.appendingPathComponent("ggml-large-v3-turbo-q8_0.bin")
        let weights = Data("lmgg".utf8) + Data(count: 1_000_001)
        try weights.write(to: q5); try weights.write(to: q8)
        try Data("not a model".utf8).write(to: fixtureDir.appendingPathComponent("ggml-incomplete.bin"))
        try weights.write(to: fixtureDir.appendingPathComponent("ggml-incomplete.bin.download"))
        var selectionSettings = Settings()
        selectionSettings.whisperModelDirs = [fixtureDir.path]
        selectionSettings.whisperModelPath = q5.path
        let choices = APIRecognitionModel.choices(settings: selectionSettings)
        expect(choices.first?.model == .application && choices.contains { $0.model == .whisper(q8.path) }, "Список включает наследование и скачанный Q8")
        expect(!choices.contains { $0.title.contains("incomplete") }, "Незагруженные и повреждённые модели не предлагаются")
        selectionSettings.hiddenModelPaths = [q8.path]
        expect(!APIRecognitionModel.choices(settings: selectionSettings).contains { $0.model == .whisper(q8.path) }, "Скрытые в распознавании модели не предлагаются")
        selectionSettings.hiddenModelPaths = []
        for model in [APIRecognitionModel.application, .whisper(q8.path), .fluidAudio(.nemotron)] {
            selectionSettings.apiRecognitionModel = model
            let restored = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(selectionSettings))
            expect(restored.apiRecognitionModel == model, "Независимый выбор API сохраняется в настройках")
        }
        selectionSettings.apiRecognitionModel = .whisper(q8.path)
        expect(selectionSettings.apiRecognitionSettings.whisperModelPath == q8.path && selectionSettings.whisperModelPath == q5.path,
               "Q8 API не изменяет Q5 диктовки")
        let fluidDir = FluidModelStore.directory(for: .nemotron)
        try FileManager.default.createDirectory(at: fluidDir, withIntermediateDirectories: true)
        try fluidDir.path.write(to: fluidDir.appendingPathComponent("installed-model"), atomically: true, encoding: .utf8)
        let fluidAvailable = APIRecognitionModel.choices(settings: selectionSettings).contains { $0.model == .fluidAudio(.nemotron) }
        expect(fluidAvailable == FluidModelStore.supported, "Скачанная FluidAudio предлагается только на совместимой архитектуре")
        expect(defaults.apiAudioFilterEnabled && defaults.apiUseVocabulary && defaults.apiMinimumSpeechDbfs == -55, "Новые настройки фильтра и словаря включены по умолчанию")
        var isolated = defaults; isolated.speechVocabulary = ["Keycloak"]
        isolated.apiUseVocabulary = false
        expect(isolated.apiRecognitionSettings.speechVocabulary.isEmpty && isolated.speechVocabulary == ["Keycloak"], "Словарь очищается только в копии API")
        expect(!isolated.apiRecognitionSettings.dictationFixPrompt.contains("Keycloak") && isolated.dictationFixPrompt.contains("Keycloak"), "Словарь AI API изолирован от AI диктовки")
        var original = isolated; original.apiUseVocabulary = true
        expect(!isolated.differsOutsideAPI(from: original), "Изменения API отделены от остальных настроек")
        original.language = "en"
        expect(isolated.differsOutsideAPI(from: original), "Изменения языка не считаются API-only")
        expect(!LocalAPIService.validPort(0) && !LocalAPIService.validPort(8798) && !LocalAPIService.validPort(8799), "Внутренние и некорректные порты запрещены")
        let zeroPCM = Data(count: 32000)
        let voicedPCM = Data(repeating: 64, count: 3200)
        expect(APIAudioFilter.retainedRange(pcm: zeroPCM, segments: [[0,16000]], threshold: -55) == nil, "Нулевая громкость отсекается даже при ложном VAD")
        expect(APIAudioFilter.retainedRange(pcm: voicedPCM, segments: [], threshold: -55) == nil, "Громкий звук без VAD-речи отсекается")
        expect(APIAudioFilter.retainedRange(pcm: voicedPCM, segments: [[0,1600]], threshold: -55) == 0..<3200, "Короткая речь сохраняется без изменения отсчётов")
        expect(APIAudioFilter.retainedRange(pcm: voicedPCM, segments: [[0,320]], threshold: -55) == nil, "Один короткий всплеск отсекается")
        let surrounded = Data(count: 16000) + voicedPCM + Data(count: 16000)
        expect(APIAudioFilter.retainedRange(pcm: surrounded, segments: [[8000,9600]], threshold: -55) == 9600..<25600, "Запас по краям ровно 200 мс, индексы в байтах")
        var lowPCM = Data()
        for _ in 0..<1600 { lowPCM.append(contentsOf: [32,0]) }
        expect(APIAudioFilter.retainedRange(pcm: lowPCM, segments: [[0,1600]], threshold: -55) == nil, "Тихая речь ниже порога отсекается")
        expect(APIAudioFilter.retainedRange(pcm: lowPCM, segments: [[0,1600]], threshold: -65) != nil, "Понижение порога сохраняет тихую речь")
        var filterSettings = Settings(); filterSettings.apiEnabled = true; filterSettings.apiPort = port(); filterSettings.apiImproveText = true
        let filteringBackend = Backend(), fixture = FilterFixture()
        var filteredAI = 0
        let filteringService = LocalAPIService(engine: filteringBackend, audioFilter: fixture, loadSettings: { filterSettings }, correct: { _,_,_,done in filteredAI += 1; done(.success("unexpected")); return {} })
        filteringService.configure(filterSettings)
        wait("API с фильтром готов") { filteringService.health()["status"] as? String == "ready" }
        let dropped = fetch(request(filterSettings.apiPort))
        expect(dropped.0 == 200 && dropped.1["text"] as? String == "" && filteringBackend.calls.isEmpty && filteredAI == 0,
               "Отсев VAD возвращает пустой 200 без ASR и AI")
        fixture.fail = true
        expect(fetch(request(filterSettings.apiPort)).0 == 503, "Сбой VAD возвращает 503, а не пустой текст")
        filteringService.stop()
        let binary = body()
        let wire = Data("POST \(LocalAPIWire.transcriptionPath) HTTP/1.1\r\nContent-Type: multipart/form-data; boundary=fixture\r\nContent-Length: \(binary.count)\r\n\r\n".utf8) + binary
        let incomplete = try LocalAPIWire.request(wire.prefix(20), receivedAt: 0)
        expect(incomplete == nil, "Неполный заголовок ожидает продолжения")
        let parsed = try LocalAPIWire.request(wire, receivedAt: 0)!
        let decoded = try LocalAPIWire.audio(parsed)
        expect(decoded == Data(repeating: 1, count: 3200), "Multipart сохраняет бинарный PCM без строковых преобразований")
        let badWires = [
            "POST / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\nx",
            "POST / HTTP/1.1\r\nContent-Length: 1048577\r\n\r\n",
            "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n",
            "GET / HTTP/1.1\r\nOrigin: https://example.test\r\n\r\n"
        ]
        for wire in badWires {
            do { _ = try LocalAPIWire.request(Data(wire.utf8), receivedAt: 0); expect(false,"Некорректный HTTP отклоняется") }
            catch { expect(true,"HTTP-валидация") }
        }
        var stereo = LiveTranscriber.wav(pcm: Data(repeating: 0, count: 3200)); stereo[22] = 2
        do { _ = try LocalAPIWire.pcm(from: stereo); expect(false,"Стерео отклоняется") } catch { expect(true,"WAV-валидация") }

        var settings = Settings(); settings.apiAudioFilterEnabled = false; settings.apiEnabled = true; settings.apiPort = port(); settings.language = "ru"
        let backend = Backend()
        var aiCalls = 0
        let service = LocalAPIService(engine: backend, loadSettings: { settings }, correct: { text, profile, key, completion in
            aiCalls += 1; completion(.success("AI:"+text)); return {}
        })
        service.configure(settings)
        wait("API слушает loopback") { service.listening }
        let apiPort = settings.apiPort
        expect(fetch(request(apiPort, path: LocalAPIWire.healthPath, method: "GET", data: nil)).0 == 200, "Health готов")
        let raw = fetch(request(apiPort))
        expect(raw.0 == 200 && (raw.1["text"] as? String)?.hasPrefix("raw:whisper:ru:") == true && aiCalls == 0, "Raw API не вызывает AI")
        let silence = fetch(request(apiPort, data: body(pcm: Data(count: 32000))))
        expect(silence.0 == 200 && silence.1["text"] as? String == "", "Проверка ktalk на тишине возвращает пустой текст")
        expect(fetch(request(apiPort, data: body(model: "other-model"))).0 == 400, "Клиент не подменяет активную модель")
        expect(fetch(request(apiPort, path: "/missing", method: "GET", data: nil)).0 == 404, "Неизвестный путь отклоняется")
        expect(fetch(request(apiPort, method: "GET", data: nil)).0 == 405, "Неверный метод отклоняется")

        settings.whisperModelDirs = [fixtureDir.path]; settings.whisperModelPath = q5.path
        settings.apiRecognitionModel = .whisper(q8.path)
        service.configure(settings)
        expect(fetch(request(apiPort)).0 == 200 && backend.calls.last?.whisperModelPath == q8.path,
               "API использует Q8 при Q5 в приложении")
        let healthQ8 = fetch(request(apiPort, path: LocalAPIWire.healthPath, method: "GET", data: nil))
        expect(healthQ8.0 == 200 && healthQ8.1["model"] as? String == LocalAPIService.modelName(settings), "Health показывает выбранную модель API")
        let stopsBeforeAppChange = backend.shutdowns
        settings.recognitionTechnology = .fluidAudio; settings.fluidModel = .parakeet
        service.configure(settings)
        expect(fetch(request(apiPort)).0 == 200 && backend.calls.last?.recognitionTechnology == .whisper
               && backend.shutdowns == stopsBeforeAppChange, "Смена технологии диктовки не перезапускает фиксированную модель API")

        backend.delay = 0.2
        let beforeSwitch = backend.calls.count
        var oldModelRequestFinished = false
        session.dataTask(with: request(apiPort)) { _, response, _ in
            DispatchQueue.main.async { oldModelRequestFinished = (response as? HTTPURLResponse)?.statusCode == 200 }
        }.resume()
        wait("Запрос на Q8 начал работу") { backend.calls.count > beforeSwitch }
        settings.apiRecognitionModel = .whisper(q5.path)
        let stopsBeforeSave = backend.shutdowns
        service.configure(settings)
        var oldModelSettings = settings; oldModelSettings.apiRecognitionModel = .whisper(q8.path)
        expect(service.loadedModelDescription?.contains(LocalAPIService.modelName(oldModelSettings)) == true,
               "Во время запроса показана загруженная прежняя модель, а не новый сохранённый выбор")
        expect(fetch(request(apiPort)).0 == 200 && oldModelRequestFinished
               && backend.calls[beforeSwitch].whisperModelPath == q8.path && backend.calls.last?.whisperModelPath == q5.path,
               "Текущий запрос сохраняет Q8, следующий использует сохранённый Q5")
        expect(backend.shutdowns == stopsBeforeSave, "Сохранение модели во время запроса не отменяет текущую работу")
        backend.delay = 0.01
        settings.apiRecognitionModel = .whisper(q8.path); service.configure(settings)
        try FileManager.default.removeItem(at: q8)
        let beforeMissing = backend.calls.count
        let missing = fetch(request(apiPort))
        expect(missing.0 == 503 && backend.calls.count == beforeMissing && service.status.contains("недоступна"),
               "Удалённая модель даёт понятный 503 без подмены или ASR")
        expect(fetch(request(apiPort, path: LocalAPIWire.healthPath, method: "GET", data: nil)).0 == 503,
               "Health недоступной модели не сообщает ready")
        try weights.write(to: q8)
        expect(fetch(request(apiPort)).0 == 200 && backend.calls.last?.whisperModelPath == q8.path,
               "Возвращённая модель снова работает без смены выбора")
        if FluidModelStore.supported {
            settings.recognitionTechnology = .whisper; settings.apiRecognitionModel = .fluidAudio(.nemotron)
            service.configure(settings)
            expect(fetch(request(apiPort)).0 == 200 && backend.calls.last?.recognitionTechnology == .fluidAudio
                   && backend.calls.last?.fluidModel == .nemotron && settings.recognitionTechnology == .whisper,
                   "FluidAudio API работает независимо от Whisper диктовки")
        }
        settings.apiRecognitionModel = .application; settings.recognitionTechnology = .whisper
        service.configure(settings)
        expect(fetch(request(apiPort)).0 == 200 && backend.calls.last?.whisperModelPath == q5.path,
               "Как в приложении возвращает наследование модели")

        backend.delay = 0.15
        var first: String?
        session.dataTask(with: request(apiPort)) { data, _, _ in
            let text = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["text"] as? String
            DispatchQueue.main.async { first = text }
        }.resume()
        let previous = backend.calls.count
        wait("Первый запрос начал ASR") { backend.calls.count > previous }
        settings.language = "en"; settings.speechVocabulary = ["Runvoice"]; settings.apiImproveText = true
        settings.recognitionTechnology = .fluidAudio; settings.fluidModel = .parakeet
        let next = fetch(request(apiPort))
        expect(first?.hasPrefix("raw:whisper:ru:") == true, "Текущий запрос сохраняет исходный профиль")
        expect(next.1["text"] as? String == "AI:raw:fluidaudio:en:Runvoice" && aiCalls == 1, "Следующий запрос использует новый движок, язык, словарь и флаг AI")
        expect(settings.dictationProviderID != nil, "API не изменяет настройку AI обычной диктовки")
        settings.apiImproveText = false

        backend.delay = 1
        let oldCalls = backend.calls.count
        let oldStops = backend.shutdowns
        let cancelled = session.dataTask(with: request(apiPort)) { _,_,_ in }
        cancelled.resume()
        wait("Отменяемый запрос начал ASR") { backend.calls.count > oldCalls }
        cancelled.cancel()
        wait("Отмена HTTP останавливает только API-движок") { backend.shutdowns > oldStops }
        backend.delay = 0.01
        expect(fetch(request(apiPort)).0 == 200, "Следующий запрос работает после отмены")

        backend.delay = 1
        var statuses: [Int] = []
        let tasks = (0..<12).map { _ -> URLSessionDataTask in
            let task = session.dataTask(with: request(apiPort)) { _, response, _ in
                DispatchQueue.main.async { statuses.append((response as? HTTPURLResponse)?.statusCode ?? 0) }
            }; task.resume(); return task
        }
        wait("Переполнение очереди возвращает 429") { statuses.contains(429) }
        tasks.forEach { $0.cancel() }
        spin(0.3)
        service.stop(); spin(0.1)

        let deadlineBackend = Backend(); deadlineBackend.delay = 1
        settings.apiPort = port()
        let deadlineService = LocalAPIService(engine: deadlineBackend, loadSettings: { settings }, requestDeadline: 0.10)
        deadlineService.configure(settings)
        wait("API для проверки deadline запущен") { deadlineService.listening }
        expect(fetch(request(settings.apiPort)).0 == 504 && deadlineBackend.shutdowns > 0, "Общий deadline отменяет запрос и возвращает 504")
        deadlineService.stop(); spin(0.1)

        // Запрос настоящей клиентской функции из соседнего проекта, без его изменения.
        settings.apiPort = apiPort; settings.recognitionTechnology = .whisper; settings.language = "ru"; settings.speechVocabulary = []
        backend.delay = 0.01
        service.configure(settings)
        wait("API для реального Node-клиента готов") { service.listening }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("ktalk-assist/src/speech-service.mjs")
        if FileManager.default.fileExists(atPath: source.path) {
            let script = Paths.state.appendingPathComponent("ktalk-client.mjs")
            let js = "import {transcribeService} from \(String(data: try JSONEncoder().encode(source.absoluteString), encoding: .utf8)!);\nconst text=await transcribeService(Buffer.alloc(3200,1),{endpoint:'http://127.0.0.1:\(apiPort)\(LocalAPIWire.transcriptionPath)',model:'runvoice-active'});if(!text.startsWith('raw:whisper:ru:'))throw Error('Unexpected response');console.log('OK: ktalk-assist transcribeService');"
            try js.write(to: script, atomically: true, encoding: .utf8)
            var finished: Int32?
            DispatchQueue.global().async {
                let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/bin/env"); child.arguments = ["node",script.path]
                do { try child.run(); child.waitUntilExit(); DispatchQueue.main.async { finished = child.terminationStatus } }
                catch { DispatchQueue.main.async { finished = -1 } }
            }
            wait("Node-клиент завершился") { finished != nil }
            expect(finished == 0, "Настоящая функция ktalk-assist совместима с API")
        } else { print("SKIP: соседний ktalk-assist недоступен") }
        // Занятый публичный порт не останавливает действующий сервис.
        let competitor = LocalAPIService(engine: Backend(), loadSettings: { settings })
        competitor.configure(settings)
        wait("Конфликт порта виден в состоянии") { competitor.status.hasPrefix("Ошибка") }
        expect(fetch(request(apiPort)).0 == 200, "Чужой listener при конфликте порта не затрагивается")
        competitor.stop()

        // Ошибки AI не записывают тело ответа, отмена закрывает его HTTP-запрос.
        let aiServer = LocalAPIHTTPServer()
        let aiPort = port()
        var aiListening = false
        var holdAI = false
        var aiDisconnected = false
        var aiReceived = false
        aiServer.onState = { state in aiListening = state == "listening" }
        aiServer.onRequest = { _, reply in
            DispatchQueue.main.async {
                aiReceived = true
                if !holdAI { reply(200, ["private": "PRIVATE_API_ERROR_BODY"]) }
            }
            return { DispatchQueue.main.async { aiDisconnected = true } }
        }
        try aiServer.start(port: UInt16(aiPort))
        wait("Тестовый AI endpoint запущен") { aiListening }
        let provider = AIProvider(name: "API fixture", kind: .openai, providerID: "", model: "fixture", baseURL: "http://127.0.0.1:\(aiPort)/v1")
        var aiResult: Result<String, Error>?
        AIClient.generate(provider: provider, system: "PRIVATE_API_PROMPT", text: "PRIVATE_API_TRANSCRIPT",
                          apiKey: "fixture-only", logDetails: false) { aiResult = $0 }
        wait("Ошибка AI разобрана") { aiResult != nil }
        let log = (try? String(contentsOf: Log.url, encoding: .utf8)) ?? ""
        expect(!log.contains("PRIVATE_API_"), "Текст и ошибка AI API не попадают в журнал")
        holdAI = true; aiReceived = false; aiDisconnected = false
        let abortAI = AIClient.generate(provider: provider, system: "fixture", text: "fixture", apiKey: "fixture-only", logDetails: false) { _ in }
        wait("Отменяемый AI запрос принят") { aiReceived }
        abortAI()
        wait("Отмена AI закрывает HTTP-запрос") { aiDisconnected }
        aiServer.stop()
        service.stop(); session.invalidateAndCancel()
        print("OK: \(checks) проверок локального API, multipart, профилей, AI, очереди, отмены и deadline")
    }
}
