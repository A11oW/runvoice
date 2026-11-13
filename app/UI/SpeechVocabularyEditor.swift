import AppKit

/// Самостоятельная таблица, чтобы редактирование словаря не зависело от истории
/// и обновления карточек моделей. Черновики сохраняются до явного исправления.
final class SpeechVocabularyEditor: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let table = NSTableView()
    let input = NSTextView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let removeButton = NSButton(title: "Удалить", target: nil, action: nil)
    private var rows: [String] = []
    private var baseline: [String] = []

    var terms: [String] { SpeechVocabulary.normalize(rows) }
    var hasChanges: Bool { rows != baseline || !input.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var validationMessage: String { errorLabel.stringValue }

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func load(_ terms: [String]) {
        window?.makeFirstResponder(nil)
        rows = terms
        baseline = terms
        input.string = ""
        table.reloadData()
        refresh()
    }

    func reset() {
        window?.makeFirstResponder(nil)
        rows = []
        input.string = ""
        table.reloadData()
        refresh()
    }

    /// Сохранение также добавляет ещё не отправленный текст в поле под таблицей.
    @discardableResult
    func commit() -> Bool {
        window?.makeFirstResponder(nil)
        return apply(rows + SpeechVocabulary.splitList(input.string))
    }

    @objc func addTerms() { _ = commit() }

    @objc func removeSelected() {
        window?.makeFirstResponder(nil)
        let selected = table.selectedRowIndexes
        rows = rows.enumerated().filter { !selected.contains($0.offset) }.map(\.element)
        table.reloadData()
        refresh()
    }

    private func apply(_ candidates: [String]) -> Bool {
        switch SpeechVocabulary.validate(candidates) {
        case .success(let terms):
            rows = terms
            input.string = ""
            table.reloadData()
            refresh()
            return true
        case .failure(let error):
            errorLabel.stringValue = error.localizedDescription
            return false
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("vocabulary-term")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? NSTableCellView()
        if cell.textField == nil {
            cell.identifier = identifier
            let field = NSTextField()
            field.isBordered = false
            field.drawsBackground = false
            field.font = .systemFont(ofSize: 13)
            field.delegate = self
            field.identifier = identifier
            field.setAccessibilityLabel("Термин")
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.textField?.stringValue = rows[row]
        return cell
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        let row = table.row(for: field)
        guard rows.indices.contains(row) else { return }
        rows[row] = field.stringValue
        refresh()
    }

    func controlTextDidEndEditing(_ notification: Notification) { controlTextDidChange(notification) }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeButton.isEnabled = table.numberOfSelectedRows > 0
    }

    private func refresh() {
        countLabel.stringValue = "\(SpeechVocabulary.normalize(rows).count) из \(SpeechVocabulary.maximumTerms)"
        removeButton.isEnabled = table.numberOfSelectedRows > 0
        if case .failure(let error) = SpeechVocabulary.validate(rows) {
            errorLabel.stringValue = error.localizedDescription
        } else {
            errorLabel.stringValue = ""
        }
    }

    private func build() {
        let note = NSTextField(wrappingLabelWithString:
            "Подсказки для Whisper, усиление терминов в Nemotron и подсказки AI-редактору. Одна строка — один термин или фраза, до 80 символов.")
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        let heading = NSTextField(labelWithString: "Технические термины")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        let header = NSStackView(views: [heading, NSView(), countLabel])
        header.orientation = .horizontal
        header.alignment = .centerY

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("term"))
        column.title = "Термин"
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.rowHeight = 28
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.delegate = self
        table.dataSource = self
        table.setAccessibilityLabel("Словарь технических терминов")
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.documentView = table

        let inputNote = NSTextField(labelWithString: "Добавьте термин или список через запятую либо с новой строки")
        inputNote.font = .systemFont(ofSize: 11)
        inputNote.textColor = .secondaryLabelColor
        input.isRichText = false
        input.font = .systemFont(ofSize: 13)
        input.allowsUndo = true
        input.isAutomaticQuoteSubstitutionEnabled = false
        input.isAutomaticDashSubstitutionEnabled = false
        input.isAutomaticSpellingCorrectionEnabled = false
        input.textContainerInset = NSSize(width: 5, height: 5)
        input.isVerticallyResizable = true
        input.isHorizontallyResizable = false
        input.autoresizingMask = [.width]
        input.textContainer?.widthTracksTextView = true
        input.setAccessibilityLabel("Новые термины")
        let inputScroll = NSScrollView()
        inputScroll.hasVerticalScroller = true
        inputScroll.autohidesScrollers = true
        inputScroll.borderType = .bezelBorder
        inputScroll.documentView = input
        let addButton = NSButton(title: "Добавить", target: self, action: #selector(addTerms))
        removeButton.target = self
        removeButton.action = #selector(removeSelected)
        let buttons = NSStackView(views: [addButton, removeButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemOrange

        for view in [note, header, scroll, inputNote, inputScroll, buttons, errorLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16).isActive = true
            view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16).isActive = true
        }
        NSLayoutConstraint.activate([
            note.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            header.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 16),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            inputNote.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12),
            inputScroll.topAnchor.constraint(equalTo: inputNote.bottomAnchor, constant: 6),
            inputScroll.heightAnchor.constraint(equalToConstant: 62),
            buttons.topAnchor.constraint(equalTo: inputScroll.bottomAnchor, constant: 8),
            errorLabel.topAnchor.constraint(equalTo: buttons.bottomAnchor, constant: 6),
            errorLabel.heightAnchor.constraint(equalToConstant: 32),
            errorLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }
}
