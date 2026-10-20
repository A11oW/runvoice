import Foundation

/// Одна запись истории распознавания.
struct HistoryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let text: String
    let raw: String?
    let model: String?
}

/// Результат последней диктовки, который пишет bin/dictate.sh.
struct LastDictationResult: Decodable {
    let raw: String?
    let fixed: String
    let model: String?
    let timestamp: TimeInterval?
}

final class HistoryStore {
    static let shared = HistoryStore()
    static let didChange = Notification.Name("RunvoiceHistoryDidChange")

    private(set) var entries: [HistoryEntry] = []
    private let url = Paths.history

    private init() {
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: url) else {
            entries = []
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([HistoryEntry].self, from: data)) ?? []
        entries.sort { $0.date > $1.date }
    }

    func add(text: String, raw: String?, model: String?, date: Date = Date()) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let settings = SettingsStore.load()
        guard settings.historyEnabled else { return }

        prune(maxItems: settings.historyMaxItems, maxDays: settings.historyMaxDays)
        entries.insert(HistoryEntry(id: UUID(), date: date, text: trimmed,
                                    raw: raw, model: model), at: 0)
        if entries.count > settings.historyMaxItems {
            entries = Array(entries.prefix(settings.historyMaxItems))
        }
        save()
        notify()
        Log.write("history: добавлена запись, всего \(entries.count)")
    }

    func prune(maxItems: Int, maxDays: Int) {
        let limit = max(1, maxItems)
        let days = max(1, maxDays)
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? .distantPast
        let before = entries
        entries.removeAll { $0.date < cutoff }
        if entries.count > limit {
            entries = Array(entries.prefix(limit))
        }
        if entries != before {
            save()
            notify()
        }
    }

    func delete(id: UUID) {
        entries.removeAll { $0.id == id }
        save()
        notify()
    }

    func clear() {
        entries = []
        save()
        notify()
        Log.write("history: очищена")
    }

    /// Забирает last_result.json после успешной диктовки.
    static func consumeLastResult() -> LastDictationResult? {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: Paths.lastResult),
              let result = try? JSONDecoder().decode(LastDictationResult.self, from: data) else {
            return nil
        }
        try? fm.removeItem(at: Paths.lastResult)
        return result
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(entries)
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: url.path)
        } catch {
            Log.write("history: ошибка сохранения: \(error.localizedDescription)")
        }
    }

    private func notify() {
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
