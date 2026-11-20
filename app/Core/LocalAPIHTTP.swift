import Foundation
import Network

struct LocalAPIError: Error {
    let status: Int
    let message: String
    init(_ status: Int, _ message: String) { self.status = status; self.message = message }
}

struct LocalAPIRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
    let receivedAt: TimeInterval
}

/// HTTP/1.1 одного запроса. Бинарное тело не преобразуется в строку.
enum LocalAPIWire {
    static let maximumBody = 1_048_576
    static let maximumHeaders = 16_384
    static let transcriptionPath = "/runvoice/v1/audio/transcriptions"
    static let healthPath = "/runvoice/v1/health"
    static let modelAlias = "runvoice-active"

    static func request(_ data: Data, receivedAt: TimeInterval) throws -> LocalAPIRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let end = data.range(of: separator) else {
            if data.count > maximumHeaders { throw LocalAPIError(431, "Слишком большие HTTP-заголовки") }
            return nil
        }
        guard end.lowerBound <= maximumHeaders,
              let text = String(data: data.prefix(end.lowerBound), encoding: .utf8) else {
            throw LocalAPIError(400, "Некорректные HTTP-заголовки")
        }
        let lines = text.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ")
        guard first.count == 3, ["HTTP/1.1", "HTTP/1.0"].contains(String(first[2])) else {
            throw LocalAPIError(400, "Некорректный HTTP-запрос")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw LocalAPIError(400, "Некорректный заголовок") }
            let name = line[..<colon].lowercased()
            guard !name.isEmpty, headers[name] == nil else { throw LocalAPIError(400, "Повторный HTTP-заголовок") }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil else { throw LocalAPIError(400, "Требуется Content-Length") }
        guard headers["origin"] == nil else { throw LocalAPIError(403, "Доступ из веб-страниц не разрешён") }
        let method = String(first[0])
        if method == "POST", headers["content-length"] == nil { throw LocalAPIError(411, "Требуется Content-Length") }
        let rawLength = headers["content-length"] ?? "0"
        guard !rawLength.isEmpty, rawLength.allSatisfy({ $0.isASCII && $0.isNumber }), let count = Int(rawLength), count >= 0 else {
            throw LocalAPIError(400, "Некорректный Content-Length")
        }
        guard count <= maximumBody else { throw LocalAPIError(413, "Аудиозапрос превышает 1 МиБ") }
        let start = end.upperBound
        guard data.count >= start + count else { return nil }
        guard data.count == start + count else { throw LocalAPIError(400, "Дополнительные данные после запроса") }
        return LocalAPIRequest(method: method, path: String(first[1]), headers: headers,
                               body: data.subdata(in: start..<(start + count)), receivedAt: receivedAt)
    }

    static func audio(_ request: LocalAPIRequest) throws -> Data {
        let contentType = request.headers["content-type"] ?? ""
        let parts = contentType.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.first?.lowercased() == "multipart/form-data",
              let parameter = parts.dropFirst().first(where: { $0.lowercased().hasPrefix("boundary=") }) else {
            throw LocalAPIError(415, "Требуется multipart/form-data")
        }
        let boundary = String(parameter.dropFirst(9)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard !boundary.isEmpty, boundary.utf8.count <= 200,
              !boundary.contains("\r"), !boundary.contains("\n") else { throw LocalAPIError(400, "Некорректная multipart-граница") }
        let data = request.body
        let delimiter = Data(("--" + boundary).utf8)
        let following = Data(("\r\n--" + boundary).utf8)
        guard data.starts(with: delimiter) else { throw LocalAPIError(400, "Некорректный multipart") }
        var cursor = delimiter.count
        var fields: [String: Data] = [:]
        while true {
            if data.count >= cursor + 2, data.subdata(in: cursor..<(cursor + 2)) == Data("--".utf8) {
                let tail = data.dropFirst(cursor + 2)
                guard tail.isEmpty || tail == Data("\r\n".utf8) else { throw LocalAPIError(400, "Некорректное завершение multipart") }
                break
            }
            guard data.count >= cursor + 2, data.subdata(in: cursor..<(cursor + 2)) == Data("\r\n".utf8),
                  let headersEnd = data.range(of: Data("\r\n\r\n".utf8), in: (cursor + 2)..<data.count),
                  headersEnd.lowerBound - cursor <= maximumHeaders,
                  let headers = String(data: data.subdata(in: (cursor + 2)..<headersEnd.lowerBound), encoding: .utf8),
                  let disposition = headers.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("content-disposition:") }),
                  let namePart = disposition.components(separatedBy: ";").map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { $0.hasPrefix("name=\"") }),
                  namePart.hasSuffix("\"") else { throw LocalAPIError(400, "Некорректная часть multipart") }
            let name = String(namePart.dropFirst(6).dropLast())
            guard fields[name] == nil, ["file", "model", "response_format"].contains(name) else {
                throw LocalAPIError(400, "Некорректное или повторное поле multipart")
            }
            let start = headersEnd.upperBound
            guard let next = data.range(of: following, in: start..<data.count) else { throw LocalAPIError(400, "Незавершённый multipart") }
            fields[name] = data.subdata(in: start..<next.lowerBound)
            cursor = next.upperBound
        }
        guard fields["model"] == Data(modelAlias.utf8), fields["response_format"] == Data("json".utf8),
              let wav = fields["file"] else { throw LocalAPIError(400, "Требуются file, model=\(modelAlias) и response_format=json") }
        return try pcm(from: wav)
    }

    static func pcm(from wav: Data) throws -> Data {
        func integer(_ offset: Int, _ size: Int) -> Int {
            (0..<size).reduce(0) { $0 | Int(wav[offset + $1]) << (8 * $1) }
        }
        guard wav.count >= 44, wav.prefix(4) == Data("RIFF".utf8), wav.subdata(in: 8..<12) == Data("WAVE".utf8),
              integer(4, 4) + 8 == wav.count else { throw LocalAPIError(415, "Требуется корректный WAV PCM16/16 кГц/моно") }
        var offset = 12
        var formatOK = false
        var payload: Data?
        while offset + 8 <= wav.count {
            let tag = wav.subdata(in: offset..<(offset + 4))
            let size = integer(offset + 4, 4)
            let start = offset + 8
            guard size <= wav.count - start else { throw LocalAPIError(400, "Повреждённый WAV") }
            if tag == Data("fmt ".utf8) {
                guard size >= 16, !formatOK, integer(start, 2) == 1, integer(start + 2, 2) == 1,
                      integer(start + 4, 4) == 16000, integer(start + 8, 4) == 32000,
                      integer(start + 12, 2) == 2, integer(start + 14, 2) == 16 else {
                    throw LocalAPIError(415, "Поддерживается WAV PCM16/16 кГц/моно")
                }
                formatOK = true
            } else if tag == Data("data".utf8) {
                guard payload == nil, size > 0, size % 2 == 0 else { throw LocalAPIError(400, "Некорректные PCM-данные") }
                payload = wav.subdata(in: start..<(start + size))
            }
            offset = start + size + size % 2
        }
        guard formatOK, let payload, offset == wav.count else { throw LocalAPIError(400, "Неполный WAV") }
        return payload
    }

    static func response(status: Int, json: [String: Any]) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data("{}".utf8)
        let reason = [200:"OK",400:"Bad Request",403:"Forbidden",404:"Not Found",405:"Method Not Allowed",408:"Request Timeout",411:"Length Required",413:"Payload Too Large",415:"Unsupported Media Type",429:"Too Many Requests",431:"Request Header Fields Too Large",500:"Internal Server Error",502:"Bad Gateway",503:"Service Unavailable",504:"Gateway Timeout"][status] ?? "Error"
        return Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n".utf8) + body
    }
}

final class LocalAPIHTTPServer {
    var onRequest: ((LocalAPIRequest, @escaping (Int, [String: Any]) -> Void) -> (() -> Void))?
    var onState: ((String) -> Void)?
    private let queue = DispatchQueue(label: "Runvoice.api.http")
    private var listener: NWListener?
    private var clients: [UUID: LocalAPIHTTPConnection] = [:]
    private var stopping = false
    private var stopCompletions: [() -> Void] = []
    func start(port: UInt16) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, self.listener === listener else { return }
            switch state {
            case .ready: DispatchQueue.main.async { self.onState?("listening") }
            case .failed: DispatchQueue.main.async { self.onState?("failed") }
            case .cancelled:
                self.listener = nil
                let completions = self.stopCompletions
                self.stopCompletions.removeAll()
                DispatchQueue.main.async { completions.forEach { $0() } }
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, !self.stopping, self.clients.count < 32 else { connection.cancel(); return }
            let id = UUID()
            let client = LocalAPIHTTPConnection(connection: connection, queue: self.queue)
            self.clients[id] = client
            client.onFinish = { [weak self] in self?.clients.removeValue(forKey: id) }
            client.handler = self.onRequest
            client.start()
        }
        listener.start(queue: queue)
    }
    func stop(completion: (() -> Void)? = nil) {
        queue.async { [self] in
            guard let listener else {
                if let completion { DispatchQueue.main.async { completion() } }
                return
            }
            if let completion { stopCompletions.append(completion) }
            guard !stopping else { return }
            stopping = true
            let active = Array(clients.values)
            active.forEach { $0.close() }
            clients.removeAll()
            listener.cancel()
        }
    }
}

private final class LocalAPIHTTPConnection {
    let connection: NWConnection
    let queue: DispatchQueue
    var handler: ((LocalAPIRequest, @escaping (Int, [String: Any]) -> Void) -> (() -> Void))?
    var onFinish: (() -> Void)?
    private var data = Data()
    private var completed = false
    private var replied = false
    private var cancellation: (() -> Void)?
    private var timer: DispatchWorkItem?
    private let receivedAt = ProcessInfo.processInfo.systemUptime
    init(connection: NWConnection, queue: DispatchQueue) { self.connection = connection; self.queue = queue }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state { case .failed, .cancelled: self?.close(); default: break }
        }
        connection.start(queue: queue)
        let timeout = DispatchWorkItem { [weak self] in self?.reply(408, ["error": ["message": "Не завершена загрузка запроса"]]) }
        timer = timeout; queue.asyncAfter(deadline: .now() + 10, execute: timeout)
        receive()
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] bytes, _, ended, error in
            guard let self, !self.completed else { return }
            if let bytes { self.data.append(bytes) }
            do {
                if let request = try LocalAPIWire.request(self.data, receivedAt: self.receivedAt) {
                    self.timer?.cancel(); self.timer = nil
                    self.data.removeAll()
                    guard let handler = self.handler else { self.reply(503, ["error": ["message": "API недоступен"]]); return }
                    self.cancellation = handler(request) { [weak self] status, json in
                        self?.queue.async { [weak self] in self?.reply(status, json) }
                    }
                    self.watchDisconnect()
                    return
                }
            } catch let error as LocalAPIError { self.reply(error.status, ["error": ["message": error.message]]); return }
            catch { self.reply(400, ["error": ["message": "Некорректный HTTP-запрос"]]); return }
            if ended || error != nil { self.close() } else { self.receive() }
        }
    }
    private func watchDisconnect() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, _, _ in self?.close() }
    }
    private func reply(_ status: Int, _ json: [String: Any]) {
        guard !completed, !replied else { return }
        replied = true
        cancellation = nil
        connection.send(content: LocalAPIWire.response(status: status, json: json), completion: .contentProcessed { [weak self] _ in self?.close() })
    }
    func close() {
        guard !completed else { return }
        completed = true
        timer?.cancel(); timer = nil
        cancellation?(); cancellation = nil
        connection.cancel()
        onFinish?(); onFinish = nil
    }
}
