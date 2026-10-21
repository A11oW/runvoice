import Foundation

/// Одноразовый вызов выбранного AI-провайдера.
enum AIClient {
    enum AIError: LocalizedError {
        case noProvider
        case noBaseURL
        case noOpenCode
        case badResponse(String)
        case emptyAnswer

        var errorDescription: String? {
            switch self {
            case .noProvider: return "Не выбран AI-провайдер"
            case .noBaseURL: return "Не задан базовый URL для своего API"
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
        switch provider.kind {
        case .openai:
            let base = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !base.isEmpty else {
                finish(.failure(AIError.noBaseURL), completion)
                return
            }
            openAIRequest(provider: provider, system: system, text: text,
                          baseURL: base, apiKey: apiKey, completion: completion)
        case .anthropic:
            let base = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !base.isEmpty else {
                finish(.failure(AIError.noBaseURL), completion)
                return
            }
            anthropicRequest(provider: provider, system: system, text: text,
                             baseURL: base, apiKey: apiKey, completion: completion)
        case .opencode:
            guard let opencode = OpenCodeLocator.find() else {
                finish(.failure(AIError.noOpenCode), completion)
                return
            }
            openCodeRequest(provider: provider, system: system, text: text,
                            binary: opencode, completion: completion)
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
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        } else if let key = Keychain.value(for: provider.keychainAccount), !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        } else if let key = ProcessInfo.processInfo.environment["OC_API_KEY"], !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = data

        URLSession.shared.dataTask(with: request) { data, _, error in
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
        if let apiKey, !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        } else if let key = Keychain.value(for: provider.keychainAccount), !key.isEmpty {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
        } else if let key = ProcessInfo.processInfo.environment["OC_API_KEY"], !key.isEmpty {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
        }
        request.httpBody = data

        URLSession.shared.dataTask(with: request) { data, _, error in
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
