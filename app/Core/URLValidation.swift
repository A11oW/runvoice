import Foundation

/// Проверка base URL для AI-провайдеров.
/// Внешние API обязаны использовать HTTPS; HTTP разрешён только для loopback.
enum AIProviderURL {
    enum ValidationError: LocalizedError {
        case empty
        case malformed
        case insecureHTTP
        case credentials
        case queryOrFragment

        var errorDescription: String? {
            switch self {
            case .empty:
                return "Не задан базовый URL API."
            case .malformed:
                return "Некорректный URL API."
            case .insecureHTTP:
                return "Для внешнего API нужен https://. HTTP разрешён только для localhost, 127.0.0.1 или ::1."
            case .credentials:
                return "URL не должен содержать логин или пароль."
            case .queryOrFragment:
                return "URL API не должен содержать query или fragment."
            }
        }
    }

    static func validateBase(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ValidationError.empty }
        guard !trimmed.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) ||
            CharacterSet.whitespacesAndNewlines.contains($0)
        }) else {
            throw ValidationError.malformed
        }
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            throw ValidationError.malformed
        }
        guard components.user == nil, components.password == nil else {
            throw ValidationError.credentials
        }
        guard components.query == nil, components.fragment == nil else {
            throw ValidationError.queryOrFragment
        }

        switch scheme {
        case "https":
            break
        case "http":
            guard isLoopback(host) else { throw ValidationError.insecureHTTP }
        default:
            throw ValidationError.malformed
        }

        guard let normalized = components.url?.absoluteString, !normalized.isEmpty else {
            throw ValidationError.malformed
        }
        return normalized
    }

    static func isLoopback(_ host: String) -> Bool {
        let value = host.lowercased()
        return value == "localhost" || value == "127.0.0.1"
            || value == "::1" || value == "[::1]"
    }
}
