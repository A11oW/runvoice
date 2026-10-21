import AppKit

/// Модальная форма добавления/редактирования AI-провайдера.
final class ProviderEditorWindow: NSWindowController, NSWindowDelegate {
    var onSave: ((AIProvider, String) -> Void)?
    var onCancel: (() -> Void)?

    private let provider: AIProvider
    private let originalName: String
    private let existingNames: Set<String>

    private var nameField: NSTextField!
    private var kindControl: NSSegmentedControl!
    private var providerField: NSTextField!
    private var modelField: NSTextField!
    private var baseURLField: NSTextField!
    private var apiKeyField: NSSecureTextField!
    private var providerGroup: NSStackView!
    private var baseURLGroup: NSStackView!
    private var apiKeyGroup: NSStackView!
    private var hint: NSTextField!
    private var testButton: NSButton!
    private var testLabel: NSTextField!
    private var isClosing = false

    init(provider: AIProvider, apiKey: String, existingNames: Set<String>) {
        self.provider = provider
        self.originalName = provider.name
        self.existingNames = existingNames

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 510),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = provider.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Новый провайдер"
            : "Редактировать провайдера"
        window.center()
        super.init(window: window)
        window.delegate = self
        build(apiKey: apiKey)
    }

    override init(window: NSWindow?) {
        fatalError("init(window:) is not supported")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func build(apiKey: String) {
        guard let content = window?.contentView else { return }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        let title = NSTextField(labelWithString: "Профиль AI-провайдера")
        title.font = .boldSystemFont(ofSize: 14)
        let subtitle = NSTextField(wrappingLabelWithString: "Название видно в «Постобработке». Ключ хранится в Keychain.")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor

        nameField = NSTextField()
        nameField.placeholderString = "Например, DeepSeek Flash"
        nameField.stringValue = provider.name

        let nameGroup = fieldGroup("Название", field: nameField)

        let kindLabel = label("Тип")
        kindControl = NSSegmentedControl(labels: ["OpenCode", "OpenAI", "Anthropic"],
                                         trackingMode: .selectOne,
                                         target: self,
                                         action: #selector(kindChanged))
        kindControl.segmentStyle = .rounded
        switch provider.kind {
        case .opencode: kindControl.selectedSegment = 0
        case .openai: kindControl.selectedSegment = 1
        case .anthropic: kindControl.selectedSegment = 2
        }
        let kindRow = NSStackView(views: [kindLabel, kindControl])
        kindRow.orientation = .horizontal
        kindRow.alignment = .centerY
        kindRow.spacing = 12

        providerField = NSTextField()
        providerField.placeholderString = "deepseek"
        providerField.stringValue = provider.providerID
        providerGroup = fieldGroup("Провайдер OpenCode", field: providerField)

        modelField = NSTextField()
        modelField.placeholderString = "deepseek-flash"
        modelField.stringValue = provider.model
        let modelGroup = fieldGroup("Модель", field: modelField)

        baseURLField = NSTextField()
        baseURLField.placeholderString = "https://api.example.com/v1"
        baseURLField.stringValue = provider.baseURL
        baseURLGroup = fieldGroup("Базовый URL (OpenAI-compatible)", field: baseURLField)

        apiKeyField = NSSecureTextField()
        apiKeyField.placeholderString = "если нужен"
        apiKeyField.stringValue = apiKey
        apiKeyGroup = fieldGroup("API-ключ", field: apiKeyField)

        hint = NSTextField(wrappingLabelWithString: "")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        testButton = NSButton(title: "Проверить подключение", target: self, action: #selector(testProvider))
        testButton.bezelStyle = .rounded
        testLabel = NSTextField(wrappingLabelWithString: "")
        testLabel.font = .systemFont(ofSize: 11)
        testLabel.textColor = .secondaryLabelColor
        testLabel.maximumNumberOfLines = 2
        let testRow = NSStackView(views: [testButton, testLabel])
        testRow.orientation = .horizontal
        testRow.alignment = .centerY
        testRow.spacing = 10

        let cancel = NSButton(title: "Отмена", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        cancel.bezelStyle = .rounded
        let save = NSButton(title: "Сохранить", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        save.bezelStyle = .rounded
        let footer = NSStackView(views: [cancel, save])
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(footer)

        let rows: [NSView] = [title, subtitle, nameGroup, kindRow, providerGroup,
                              modelGroup, baseURLGroup, apiKeyGroup, hint, testRow]
        for row in rows {
            stack.addArrangedSubview(row)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),

            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: footer.topAnchor, constant: -12),
        ])

        kindChanged()
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        return field
    }

    private func fieldGroup(_ title: String, field: NSTextField) -> NSStackView {
        let stack = NSStackView(views: [label(title), field])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        field.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private var selectedKind: AIProviderKind {
        switch kindControl.selectedSegment {
        case 1: return .openai
        case 2: return .anthropic
        default: return .opencode
        }
    }

    @objc private func kindChanged() {
        let kind = selectedKind
        let api = kind.usesAPIKey
        providerGroup?.isHidden = api
        baseURLGroup?.isHidden = !api
        apiKeyGroup?.isHidden = !api
        if kind == .anthropic {
            baseURLField.placeholderString = "https://api.anthropic.com"
            hint?.stringValue = "Запросы идут в {URL}/v1/messages. Заголовки: x-api-key и anthropic-version."
        } else if kind == .openai {
            baseURLField.placeholderString = "https://api.openai.com/v1"
            hint?.stringValue = "Запросы идут в {URL}/chat/completions с Authorization: Bearer."
        } else {
            hint?.stringValue = "Провайдер и модель должны быть доступны в OpenCode CLI."
        }
        testLabel?.stringValue = ""
    }

    private func currentProvider() -> AIProvider {
        var result = provider
        result.name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        result.kind = selectedKind
        result.providerID = providerField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        result.model = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        result.baseURL = baseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }

    @objc private func testProvider() {
        let candidate = currentProvider()
        testButton.isEnabled = false
        testLabel.stringValue = "Проверяю…"
        testLabel.textColor = .secondaryLabelColor
        let key = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        CorrectionTester.test(provider: candidate,
                              prompt: DefaultPrompts.fix,
                              apiKey: key) { [weak self] result in
            guard let self else { return }
            self.testButton.isEnabled = true
            switch result {
            case .success(let text):
                self.testLabel.stringValue = "✓ \(text)"
                self.testLabel.textColor = .systemGreen
            case .failure(let error):
                self.testLabel.stringValue = "⚠️ \(error.localizedDescription)"
                self.testLabel.textColor = .systemOrange
            }
        }
    }

    @objc private func save() {
        let candidate = currentProvider()
        guard !candidate.name.isEmpty else {
            alert("Укажите название провайдера.")
            return
        }
        guard !candidate.model.isEmpty else {
            alert("Укажите модель.")
            return
        }
        if candidate.kind == .opencode {
            guard !candidate.providerID.isEmpty else {
                alert("Укажите provider ID OpenCode.")
                return
            }
        } else {
            guard !candidate.baseURL.isEmpty else {
                alert("Укажите базовый URL для своего API.")
                return
            }
            guard candidate.baseURL.lowercased().hasPrefix("http://")
                    || candidate.baseURL.lowercased().hasPrefix("https://") else {
                alert("URL должен начинаться с http:// или https://.")
                return
            }
        }
        let duplicate = existingNames.contains {
            $0.lowercased() == candidate.name.lowercased()
        }
        guard !duplicate else {
            alert("Провайдер с таким названием уже существует.")
            return
        }

        let key = candidate.kind.usesAPIKey
            ? apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        onSave?(candidate, key)
        closeSheet()
    }

    @objc private func cancel() {
        onCancel?()
        closeSheet()
    }

    func windowWillClose(_ notification: Notification) {
        guard !isClosing else { return }
        isClosing = true
        NSApp.stopModal(withCode: .cancel)
        onCancel?()
    }

    private func closeSheet() {
        guard !isClosing else { return }
        isClosing = true
        NSApp.stopModal(withCode: .OK)
        window?.close()
    }

    private func alert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Проверьте профиль"
        alert.informativeText = message
        alert.runModal()
    }
}
