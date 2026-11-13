import AppKit

/// Доставка результата без запуска pbcopy. Работает в главном потоке.
final class DictationPasteboard {
    private let pasteboard: NSPasteboard
    private let restoreDelay: TimeInterval
    private var pendingRestore: DispatchWorkItem?
    private var generation = UUID()

    init(pasteboard: NSPasteboard = .general, restoreDelay: TimeInterval = 0.5) {
        self.pasteboard = pasteboard
        self.restoreDelay = restoreDelay
    }

    @discardableResult
    func deliver(_ text: String, restoreClipboard: Bool, sendPaste: () -> Bool) -> Bool {
        generation = UUID()
        let token = generation
        pendingRestore?.cancel()
        let saved = restoreClipboard ? snapshot() : []
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let changeCount = pasteboard.changeCount
        let sent = sendPaste()
        // Без Accessibility текст остаётся доступен для ручного ⌘V.
        guard restoreClipboard, sent else { return sent }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token,
                  self.pasteboard.changeCount == changeCount else { return }
            self.pasteboard.clearContents()
            let items = saved.map { values -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { self.pasteboard.writeObjects(items) }
        }
        pendingRestore = work
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay, execute: work)
        return sent
    }

    private func snapshot() -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var values: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { values[type] = data }
            }
            return values
        }
    }

    deinit { pendingRestore?.cancel() }
}
