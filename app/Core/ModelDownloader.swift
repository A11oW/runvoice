import Foundation
import CryptoKit

/// Загрузка одной модели из каталога с проверкой SHA-256.
final class ModelDownloader: NSObject, URLSessionDownloadDelegate {
    enum DownloadError: LocalizedError {
        case badStatus(Int)
        case checksumMismatch
        case fileSystem(String)

        var errorDescription: String? {
            switch self {
            case .badStatus(let code): return "Сервер вернул HTTP \(code)"
            case .checksumMismatch: return "Контрольная сумма не совпала — файл повреждён"
            case .fileSystem(let text): return text
            }
        }
    }

    let model: WhisperModel
    var onProgress: ((Double, Double) -> Void)?
    var onFinish: ((Result<URL, Error>) -> Void)?

    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private var completed = false
    private let startedAt = Date()

    init(model: WhisperModel) {
        self.model = model
    }

    func start() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        self.session = session
        let task = session.downloadTask(with: model.url)
        self.task = task
        task.resume()
    }

    func cancel() {
        cancelled = true
        task?.cancel()
        session?.invalidateAndCancel()
        cleanupTemp()
    }

    private var destination: URL { WhisperModelStore.managedURL(for: model) }
    private var tempURL: URL { destination.appendingPathExtension("download") }

    private func cleanupTemp() {
        try? FileManager.default.removeItem(at: tempURL)
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        let elapsed = Date().timeIntervalSince(startedAt)
        let speed = elapsed > 0.2 ? Double(totalBytesWritten) / elapsed : 0
        onProgress?(progress, speed)
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard !cancelled else { return }
        if let response = downloadTask.response as? HTTPURLResponse,
           response.statusCode != 200 {
            finish(.failure(DownloadError.badStatus(response.statusCode)))
            return
        }

        do {
            try FileManager.default.createDirectory(at: WhisperModelStore.modelsDirectory,
                                                    withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: tempURL)
            try FileManager.default.moveItem(at: location, to: tempURL)
        } catch {
            finish(.failure(DownloadError.fileSystem(error.localizedDescription)))
            return
        }

        let temp = tempURL
        let model = self.model
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let hash = Self.sha256(of: temp)
            DispatchQueue.main.async {
                guard let self, !self.cancelled else { return }
                guard hash == model.sha256 else {
                    self.cleanupTemp()
                    self.finish(.failure(DownloadError.checksumMismatch))
                    return
                }
                do {
                    let destination = WhisperModelStore.managedURL(for: model)
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: temp, to: destination)
                    self.finish(.success(destination))
                } catch {
                    self.cleanupTemp()
                    self.finish(.failure(DownloadError.fileSystem(error.localizedDescription)))
                }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !completed, !cancelled, let error else { return }
        finish(.failure(error))
    }

    private func finish(_ result: Result<URL, Error>) {
        guard !completed else { return }
        completed = true
        session?.finishTasksAndInvalidate()
        session = nil
        onFinish?(result)
    }

    private static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = (try? handle.read(upToCount: 1 << 20)) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
