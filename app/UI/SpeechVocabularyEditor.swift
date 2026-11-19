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
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = SettingsStyle.sectionSpacing
        root.translatesAutoresizingMaskIntoConstraints = false

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        let headerTitle = SettingsText.rowSubtitle("Терминов", width: 120)
        let header = NSStackView(views: [headerTitle, NSView(), countLabel])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.arrangedSubviews[1].setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("term"))
        column.title = "Термин"
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.rowHeight = 28
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = .clear
        table.allowsMultipleSelection = true
        table.delegate = self
        table.dataSource = self
        table.setAccessibilityLabel("Словарь технических терминов")
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.documentView = table
        scroll.heightAnchor.constraint(equalToConstant: 220).isActive = true

        let termsCard = SettingsCard()
        termsCard.addRow(SettingsContentRow(header, verticalInset: 10))
        termsCard.addRow(SettingsContentRow(scroll, verticalInset: 0))
        let termsNote = [
            "Whisper — термины передаются как подсказка при распознавании.",
            "Nemotron — термины передаются в словарь потоковой модели.",
            "Parakeet и Phonon — термины учитываются только при AI-правке; при отключённой AI-правке словарь для них не применяется.",
            "При включённой AI-правке словарь дополнительно учитывается для всех моделей."
        ].joined(separator: " ")

        input.isRichText = false
        input.font = .systemFont(ofSize: 13)
        input.allowsUndo = true
        input.isAutomaticQuoteSubstitutionEnabled = false
        input.isAutomaticDashSubstitutionEnabled = false
        input.isAutomaticSpellingCorrectionEnabled = false
        input.textContainerInset = NSSize(width: 6, height: 6)
        input.isVerticallyResizable = true
        input.isHorizontallyResizable = false
        input.autoresizingMask = [.width]
        input.textContainer?.widthTracksTextView = true
        input.drawsBackground = false
        input.setAccessibilityLabel("Новые термины")
        let inputScroll = NSScrollView()
        inputScroll.hasVerticalScroller = true
        inputScroll.autohidesScrollers = true
        inputScroll.borderType = .bezelBorder
        inputScroll.focusRingType = .none
        inputScroll.documentView = input
        inputScroll.heightAnchor.constraint(equalToConstant: 74).isActive = true

        let addButton = SettingsText.secondaryButton("Добавить", target: self, action: #selector(addTerms))
        removeButton.bezelStyle = .rounded
        removeButton.target = self
        removeButton.action = #selector(removeSelected)
        let buttons = NSStackView(views: [addButton, removeButton, NSView()])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.arrangedSubviews.last?.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemOrange
        errorLabel.maximumNumberOfLines = 0
        errorLabel.preferredMaxLayoutWidth = SettingsStyle.contentMaxWidth - 32

        let inputBlock = NSStackView()
        inputBlock.orientation = .vertical
        inputBlock.alignment = .leading
        inputBlock.spacing = 8
        inputBlock.addArrangedFullWidth(inputScroll)
        inputBlock.addArrangedFullWidth(buttons)
        inputBlock.addArrangedFullWidth(errorLabel)

        let inputCard = SettingsCard()
        inputCard.addRow(SettingsContentRow(inputBlock, verticalInset: 12))

        root.addArrangedFullWidth(SettingsSection(title: "Технические термины", note: termsNote, card: termsCard))
        root.addArrangedFullWidth(SettingsSection(title: "Добавить термины",
                                                  note: "Одна строка — один термин или фраза, до 80 символов. Можно вставить список через запятую или с новой строки.",
                                                  card: inputCard))
        addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: topAnchor),
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
}
