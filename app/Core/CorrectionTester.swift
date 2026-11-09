import Foundation

/// Одноразовый вызов выбранного AI-провайдера.
enum AIClient {
    enum AIError: LocalizedError {
        case noProvider
        case noBaseURL
        case invalidBaseURL(String)
        case noOpenCode
        case badResponse(String)
        case emptyAnswer

        var errorDescription: String? {
            switch self {
            case .noProvider: return "Не выбран AI-провайдер"
            case .noBaseURL: return "Не задан базовый URL для своего API"
            case .invalidBaseURL(let text): return text
            case .noOpenCode: return "OpenCode CLI не найден"
            case .badResponse(let text): return "Некорректный ответ: \(text)"
            case .emptyAnswer: return "Модель вернула пустой ответ"
            }
        }
    }

    static func generate(provider: AIProvider,
                         system: String,
                         text: String,
                         apiKey: String? = nil,
                         completion: @escaping (Result<String, Error>) -> Void) {
        let started = Date()
        let kind = provider.kind.rawValue
        let timedCompletion: (Result<String, Error>) -> Void = { result in
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            switch result {
            case .success:
                Log.write("ai: provider=\(provider.displayTitle) kind=\(kind) model=\(provider.model) elapsed=\(elapsed)ms")
            case .failure(let error):
                let message = error.localizedDescription
                    .replacingOccurrences(of: "\n", with: " ")
                Log.write("ai: provider=\(provider.displayTitle) kind=\(kind) model=\(provider.model) elapsed=\(elapsed)ms error=\(message.prefix(200))")
            }
            completion(result)
        }

        switch provider.kind {
        case .openai:
            let base: String
            do {
                base = try AIProviderURL.validateBase(provider.baseURL)
            } catch {
                finish(.failure(AIError.invalidBaseURL(error.localizedDescription)), timedCompletion)
                return
            }
            openAIRequest(provider: provider, system: system, text: text,
                          baseURL: base, apiKey: apiKey, completion: timedCompletion)
        case .anthropic:
            let base: String
            do {
                base = try AIProviderURL.validateBase(provider.baseURL)
            } catch {
                finish(.failure(AIError.invalidBaseURL(error.localizedDescription)), timedCompletion)
                return
            }
            anthropicRequest(provider: provider, system: system, text: text,
                             baseURL: base, apiKey: apiKey, completion: timedCompletion)
        case .opencode:
            guard let opencode = OpenCodeLocator.find() else {
                finish(.failure(AIError.noOpenCode), timedCompletion)
                return
            }
            openCodeRequest(provider: provider, system: system, text: text,
                            binary: opencode, completion: timedCompletion)
        }
    }

    private static func openAIRequest(provider: AIProvider,
                                      system: String,
                                      text: String,
                                      baseURL: String,
                                      apiKey: String?,
                                      completion: @escaping (Result<String, Error>) -> Void) {
        let urlString: String
        if baseURL.hasSuffix("/chat/completions") {
            urlString = baseURL
        } else {
            urlString = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions"
        }
        guard let url = URL(string: urlString) else {
            finish(.failure(AIError.badResponse("некорректный URL \(urlString)")), completion)
            return
        }

        let payload: [String: Any] = [
            "model": provider.model.isEmpty ? "deepseek-flash" : provider.model,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": "<text>\(text)</text>"],
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            finish(.failure(AIError.badResponse("не удалось собрать JSON")), completion)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = sanitizedKey(apiKey)
            ?? sanitizedKey(Keychain.value(for: provider.keychainAccount))
            ?? sanitizedKey(ProcessInfo.processInfo.environment["OC_API_KEY"]) {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = data

        session.dataTask(with: request) { data, _, error in
            if let error {
                finish(.failure(error), completion)
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let text = message["content"] as? String else {
                let raw = data.flatMap { String(data: $0, encoding: .utf8) } ?? "пусто"
                finish(.failure(AIError.badResponse(String(raw.prefix(200)))), completion)
                return
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                finish(.failure(AIError.emptyAnswer), completion)
                return
            }
            finish(.success(text), completion)
        }.resume()
    }

    private static func anthropicRequest(provider: AIProvider,
                                         system: String,
                                         text: String,
                                         baseURL: String,
                                         apiKey: String?,
                                         completion: @escaping (Result<String, Error>) -> Void) {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        let urlString: String
        if base.hasSuffix("/v1/messages") || base.hasSuffix("/messages") {
            urlString = base
        } else if base.hasSuffix("/v1") {
            urlString = base + "/messages"
        } else {
            urlString = base + "/v1/messages"
        }
        guard let url = URL(string: urlString) else {
            finish(.failure(AIError.badResponse("некорректный URL \(urlString)")), completion)
            return
        }

        let payload: [String: Any] = [
            "model": provider.model.isEmpty ? "claude-sonnet-4-20250514" : provider.model,
            "max_tokens": 4096,
            "temperature": 0,
            "system": system,
            "messages": [
                ["role": "user", "content": "<text>\(text)</text>"],
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            finish(.failure(AIError.badResponse("не удалось собрать JSON")), completion)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if let key = sanitizedKey(apiKey)
            ?? sanitizedKey(Keychain.value(for: provider.keychainAccount))
            ?? sanitizedKey(ProcessInfo.processInfo.environment["OC_API_KEY"]) {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
        }
        request.httpBody = data

        session.dataTask(with: request) { data, _, error in
            if let error {
                finish(.failure(error), completion)
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let blocks = json["content"] as? [[String: Any]] else {
                let raw = data.flatMap { String(data: $0, encoding: .utf8) } ?? "пусто"
                finish(.failure(AIError.badResponse(String(raw.prefix(200)))), completion)
                return
            }
            let text = blocks.compactMap { $0["text"] as? String }.joined()
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                finish(.failure(AIError.emptyAnswer), completion)
                return
            }
            finish(.success(text), completion)
        }.resume()
    }

    private static func openCodeRequest(provider: AIProvider,
                                        system: String,
                                        text: String,
                                        binary: String,
                                        completion: @escaping (Result<String, Error>) -> Void) {
        let prompt = system + "\n\n<text>" + text + "</text>"
        let payload: [String: Any] = [
            "prompt": prompt,
            "model": [
                "providerID": provider.providerID.isEmpty ? "deepseek" : provider.providerID,
                "id": provider.model.isEmpty ? "deepseek-flash" : provider.model,
                "variant": "none",
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let body = String(data: data, encoding: .utf8) else {
            finish(.failure(AIError.badResponse("не удалось собрать JSON")), completion)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["api", "post", "/api/experimental/generate", "--data", body]
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:"
                + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            process.environment = environment
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                finish(.failure(error), completion)
                return
            }

            let output = out.fileHandleForReading.readDataToEndOfFile()
            let errorData = err.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0 else {
                let text = String(data: errorData, encoding: .utf8) ?? ""
                finish(.failure(AIError.badResponse(String(text.prefix(300)))), completion)
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
                  let dataObject = json["data"] as? [String: Any],
                  let text = dataObject["text"] as? String else {
                let text = String(data: output, encoding: .utf8) ?? "пусто"
                finish(.failure(AIError.badResponse(String(text.prefix(300)))), completion)
                return
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                finish(.failure(AIError.emptyAnswer), completion)
                return
            }
            finish(.success(text), completion)
        }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 90
        return URLSession(configuration: configuration,
                          delegate: RedirectGuard(),
                          delegateQueue: nil)
    }()

    private static func sanitizedKey(_ value: String?) -> String? {
        guard let value else { return nil }
        let key = value
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    private static func finish(_ result: Result<String, Error>,
                               _ completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.main.async { completion(result) }
    }
}

/// Проверка выбранного профиля/промпта на тестовой фразе.
enum CorrectionTester {
    static let sample = "это проверка связи с моделью, проверка связи"

    static func test(provider: AIProvider,
                     prompt: String,
                     apiKey: String? = nil,
                     completion: @escaping (Result<String, Error>) -> Void) {
        let system = prompt.isEmpty ? DefaultPrompts.fix : prompt
        AIClient.generate(provider: provider, system: system, text: sample,
                          apiKey: apiKey, completion: completion)
    }
}


private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let original = task.originalRequest?.url,
              let target = request.url,
              original.scheme?.lowercased() == target.scheme?.lowercased(),
              original.host?.lowercased() == target.host?.lowercased(),
              original.port == target.port,
              (try? AIProviderURL.validateBase(target.absoluteString)) != nil else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
