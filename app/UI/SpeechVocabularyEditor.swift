import AppKit

/// Самостоятельная таблица, чтобы редактирование словаря не зависело от истории
/// и обновления карточек моделей. Черновики сохраняются до явного исправления.
final class SpeechVocabularyEditor: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private var dataTable: SettingsDataTable!
    var table: NSTableView { dataTable.table }
    let input = NSTextView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private lazy var removeButton = SettingsDataTable.iconButton("minus", "Удалить выбранные термины", target: self, action: #selector(removeSelected))
    private var marked = IndexSet()
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
        marked.removeAll()
        rows = terms
        baseline = terms
        input.string = ""
        table.reloadData()
        refresh()
    }

    func reset() {
        window?.makeFirstResponder(nil)
        marked.removeAll()
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
        rows = rows.enumerated().filter { !marked.contains($0.offset) }.map(\.element)
        marked.removeAll()
        table.reloadData()
        refresh()
    }

    private func apply(_ candidates: [String]) -> Bool {
        switch SpeechVocabulary.validate(candidates) {
        case .success(let terms):
            if rows != terms { marked.removeAll() }
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
        if tableColumn?.identifier.rawValue == "mark" {
            let check = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleMark(_:)))
            check.state = marked.contains(row) ? .on : .off
            check.setAccessibilityLabel("Выбрать термин \(rows[row])")
            return SettingsDataTable.padded(check, centered: true)
        }
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

    @objc private func toggleMark(_ sender: NSButton) {
        let row = table.row(for: sender)
        guard rows.indices.contains(row) else { return }
        if sender.state == .on { marked.insert(row) } else { marked.remove(row) }
        refresh()
    }

    private func refresh() {
        dataTable.showCount(rows.count, selected: marked.count)
        removeButton.isEnabled = !marked.isEmpty
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

        dataTable = SettingsDataTable("Словарь технических терминов",
                                     columns: [.init(id: "mark", title: "", width: 36, fixed: true),
                                               .init(id: "term", title: "Термин", width: 580)],
                                     actions: [removeButton], empty: "Нет терминов")
        table.delegate = self
        table.dataSource = self
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
        let addRow = NSStackView(views: [inputScroll, addButton])
        addRow.alignment = .top
        addRow.spacing = 8
        addButton.setContentHuggingPriority(.required, for: .horizontal)
        addButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemOrange
        errorLabel.maximumNumberOfLines = 0
        errorLabel.preferredMaxLayoutWidth = SettingsStyle.contentMaxWidth - 32

        let inputBlock = NSStackView()
        inputBlock.orientation = .vertical
        inputBlock.alignment = .leading
        inputBlock.spacing = 8
        inputBlock.addArrangedFullWidth(addRow)
        inputBlock.addArrangedFullWidth(errorLabel)

        let inputCard = SettingsCard()
        inputCard.addRow(SettingsContentRow(inputBlock, verticalInset: 12))

        root.addArrangedFullWidth(SettingsSection(title: "Технические термины", note: termsNote, card: dataTable))
        root.addArrangedFullWidth(SettingsSection(title: "Добавить термины",
                                                  note: "Одна строка — один термин или фраза, до 80 символов. Можно вставить список через запятую или с новой строки. До \(SpeechVocabulary.maximumTerms) терминов.",
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
