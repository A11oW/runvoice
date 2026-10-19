import Foundation

/// Проверка выбранного микрофона: 1 секунда записи через dictate.sh mic-test.
enum MicTester {
    enum TestError: LocalizedError {
        case missingScript
        case busy
        case notFound
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .missingScript: return "Не найден dictate.sh"
            case .busy: return "Идёт диктовка — повторите позже"
            case .notFound: return "Микрофон не найден"
            case .failed(let text): return text
            }
        }
    }

    static func test(micName: String,
                     completion: @escaping (Result<String, Error>) -> Void) {
        guard let script = Paths.script else {
            completion(.failure(TestError.missingScript))
            return
        }

        var environment = ProcessInfo.processInfo.environment
        environment["DICTATE_STATE_DIR"] = Paths.state.path
        if !micName.isEmpty { environment["MIC_NAME"] = micName }
        let base = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = base + ":" + (environment["PATH"] ?? "")

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [script.path, "mic-test"]
            process.environment = environment
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }

            let output = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let errorOutput = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let level = output.split(separator: "\n")
                .first { $0.hasPrefix("level=") }
                .map { String($0.dropFirst("level=".count)) }
            if output.contains("error=busy") {
                DispatchQueue.main.async { completion(.failure(TestError.busy)) }
                return
            }
            if output.contains("error=notfound") {
                DispatchQueue.main.async { completion(.failure(TestError.notFound)) }
                return
            }
            guard let level, level != "unknown", level != "" else {
                let message = errorOutput.isEmpty ? "не удалось измерить уровень" : String(errorOutput.prefix(200))
                DispatchQueue.main.async { completion(.failure(TestError.failed(message))) }
                return
            }
            DispatchQueue.main.async { completion(.success(level)) }
        }
    }
}
