import AppKit
import Carbon.HIToolbox
import ApplicationServices
import UniformTypeIdentifiers

// MARK: - Окно настроек

final class SettingsWindow: NSWindowController, NSWindowDelegate {
    private let fixText = NSTextView()
    private var tabView: NSTabView!
    private var languagePopup: NSPopUpButton!
    private var providerField: NSTextField!
    private var modelField: NSTextField!
    private var baseURLField: NSTextField!
    private var useOpenCodeCheck: NSButton!
    private var restoreCheck: NSButton!
    private var hudCheck: NSButton!
    private var toggleHotkeyButton: NSButton!
    private var accessLabel: NSTextField!
    private var accessButton: NSButton!
    private var modelsStack: NSStackView!
    private var modelsDiskLabel: NSTextField!
    private var modelDirs: [String] = []
    private var hiddenModelPaths: [String] = []
    private var selectedModelPath = ""
    private var downloads: [String: ModelDownloader] = [:]
    private var downloadProgress: [String: Double] = [:]
    private var downloadBars: [String: NSProgressIndicator] = [:]
    private var downloadPercents: [String: NSTextField] = [:]
    private var depStack: NSStackView!
    private var depLabels: [NSTextField] = []
    private var refreshTimer: Timer?
    private var captureMonitor: Any?
    private var captureTarget: NSButton?
    private var toggleHotkey = HotKeySetting()

    var onCaptureStateChanged: ((Bool) -> Void)?
    var onSettingsSaved: (() -> Void)?

    private let languages = ["ru", "en", "auto"]

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Runvoice — Настройки"
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        window.delegate = self
        build()
    }

    override init(window: NSWindow?) {
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        loadValues()
        refreshDiagnostics()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self, self.window?.isVisible == true else { timer.invalidate(); return }
            self.refreshDiagnostics()
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        stopCapture()
    }

    func selectTab(_ identifier: String) {
        tabView.selectTabViewItem(withIdentifier: identifier)
    }

    private func build() {
        guard let content = window?.contentView else { return }

        tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tabView)

        let general = NSTabViewItem(identifier: "general")
        general.label = "General"
        general.view = buildGeneral()
        tabView.addTabViewItem(general)

        let ai = NSTabViewItem(identifier: "ai")
        ai.label = "AI"
        ai.view = buildAI()
        tabView.addTabViewItem(ai)

        let models = NSTabViewItem(identifier: "models")
        models.label = "Модели"
        models.view = buildModels()
        tabView.addTabViewItem(models)

        let prompt = NSTabViewItem(identifier: "prompt")
        prompt.label = "Prompt"
        prompt.view = buildPrompt()
        tabView.addTabViewItem(prompt)

        let hotkeys = NSTabViewItem(identifier: "hotkeys")
        hotkeys.label = "Hotkeys"
        hotkeys.view = buildHotkeys()
        tabView.addTabViewItem(hotkeys)

        let reset = NSButton(title: "Сбросить", target: self, action: #selector(resetDefaults))
        let cancel = NSButton(title: "Отмена", target: self, action: #selector(cancel))
        let save = NSButton(title: "Сохранить", target: self, action: #selector(saveSettings))
        save.keyEquivalent = "\r"

        for view in [reset, cancel, save] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }

        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            tabView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            tabView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            tabView.bottomAnchor.constraint(equalTo: save.topAnchor, constant: -12),

            reset.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            reset.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            save.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            save.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            cancel.trailingAnchor.constraint(equalTo: save.leadingAnchor, constant: -8),
            cancel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
    }

    // MARK: - General

    private func buildGeneral() -> NSView {
        let view = NSView()
        let languageLabel = label("Язык распознавания")
        let diagLabel = label("Диагностика", bold: true)

        languagePopup = NSPopUpButton()
        languagePopup.addItems(withTitles: ["Русский", "English", "Авто"])

        restoreCheck = NSButton(checkboxWithTitle: "Возвращать прежний буфер обмена после вставки",
                                target: nil, action: nil)
        hudCheck = NSButton(checkboxWithTitle: "Показывать всплывающий бабл статуса",
                            target: nil, action: nil)

        accessLabel = label("Accessibility: проверка…")
        accessButton = NSButton(title: "Открыть настройки", target: self, action: #selector(openAccessibility))

        depStack = NSStackView()
        depStack.orientation = .vertical
        depStack.alignment = .leading
        depStack.spacing = 4
        depStack.translatesAutoresizingMaskIntoConstraints = false
        depLabels = Dependency.allCases.map { _ in label("") }
        for depLabel in depLabels {
            depLabel.translatesAutoresizingMaskIntoConstraints = false
            depStack.addArrangedSubview(depLabel)
        }

        let views: [NSView] = [languageLabel, languagePopup, restoreCheck, hudCheck,
                               diagLabel, accessLabel, accessButton]
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        view.addSubview(depStack)

        NSLayoutConstraint.activate([
            languageLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            languageLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            languagePopup.centerYAnchor.constraint(equalTo: languageLabel.centerYAnchor),
            languagePopup.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            languagePopup.widthAnchor.constraint(equalToConstant: 200),

            restoreCheck.topAnchor.constraint(equalTo: languageLabel.bottomAnchor, constant: 20),
            restoreCheck.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),

            hudCheck.topAnchor.constraint(equalTo: restoreCheck.bottomAnchor, constant: 8),
            hudCheck.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),

            diagLabel.topAnchor.constraint(equalTo: hudCheck.bottomAnchor, constant: 24),
            diagLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),

            accessLabel.centerYAnchor.constraint(equalTo: accessButton.centerYAnchor),
            accessLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            accessButton.topAnchor.constraint(equalTo: diagLabel.bottomAnchor, constant: 8),
            accessButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            depStack.topAnchor.constraint(equalTo: accessButton.bottomAnchor, constant: 10),
            depStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            depStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
        ])

        return view
    }

    // MARK: - AI

    private func buildAI() -> NSView {
        let view = NSView()
        let providerLabel = label("Провайдер модели правки")
        let modelLabel = label("Модель правки")
        let baseURLLabel = label("Базовый URL (OpenAI-compatible)")
        let hint = label("Пусто — через OpenCode (если включён).\nЕсли задан URL — напрямую в {URL}/chat/completions.\nБез OpenCode и без URL — текст вставится без правки.")
        let note = label("Ключ доступа, если нужен: переменная окружения OC_API_KEY.")

        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 3
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 2

        providerField = NSTextField()
        providerField.placeholderString = "deepseek"
        modelField = NSTextField()
        modelField.placeholderString = "deepseek-flash"
        baseURLField = NSTextField()
        baseURLField.placeholderString = "https://api.example.com/v1"
        useOpenCodeCheck = NSButton(checkboxWithTitle: "Использовать OpenCode CLI (если базовый URL не задан)",
                                    target: nil, action: nil)

        let views: [NSView] = [providerLabel, providerField, modelLabel, modelField,
                               baseURLLabel, baseURLField, useOpenCodeCheck, hint, note]
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }

        NSLayoutConstraint.activate([
            providerLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            providerLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            providerField.topAnchor.constraint(equalTo: providerLabel.bottomAnchor, constant: 6),
            providerField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            providerField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            modelLabel.topAnchor.constraint(equalTo: providerField.bottomAnchor, constant: 16),
            modelLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            modelField.topAnchor.constraint(equalTo: modelLabel.bottomAnchor, constant: 6),
            modelField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            modelField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            baseURLLabel.topAnchor.constraint(equalTo: modelField.bottomAnchor, constant: 16),
            baseURLLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            baseURLField.topAnchor.constraint(equalTo: baseURLLabel.bottomAnchor, constant: 6),
            baseURLField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            baseURLField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            useOpenCodeCheck.topAnchor.constraint(equalTo: baseURLField.bottomAnchor, constant: 14),
            useOpenCodeCheck.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            useOpenCodeCheck.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),

            hint.topAnchor.constraint(equalTo: useOpenCodeCheck.bottomAnchor, constant: 12),
            hint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            hint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            note.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 6),
            note.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            note.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
        ])

        return view
    }

    // MARK: - Модели

    private func buildModels() -> NSView {
        let view = NSView()

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        view.addSubview(scroll)

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc

        modelsStack = NSStackView()
        modelsStack.orientation = .vertical
        modelsStack.alignment = .leading
        modelsStack.spacing = 10
        modelsStack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        modelsStack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(modelsStack)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            modelsStack.topAnchor.constraint(equalTo: doc.topAnchor),
            modelsStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            modelsStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            modelsStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])

        return view
    }

    private func refreshModels() {
        guard modelsStack != nil else { return }

        for sub in modelsStack.arrangedSubviews {
            modelsStack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }
        downloadBars.removeAll()
        downloadPercents.removeAll()

        let active = WhisperModelStore.file(at: selectedModelPath)
        var found = WhisperModelStore.foundModels(extraDirectories: modelDirs,
                                                  excluding: hiddenModelPaths)
        if let active, !found.contains(where: { $0.path == active.path }) {
            found.insert(active, at: 0)
        }

        // Баннер состояния
        let banner = NSTextField(wrappingLabelWithString: "")
        banner.font = .systemFont(ofSize: 12)
        if selectedModelPath.isEmpty {
            banner.stringValue = "Модель не выбрана. Скачайте модель или добавьте уже скачанную."
            banner.textColor = .systemOrange
        } else if let active {
            banner.stringValue = "Активная модель: \(active.fileName) · \(active.sizeText)"
            banner.textColor = .secondaryLabelColor
        } else {
            banner.stringValue = "Выбранная модель недоступна: \(selectedModelPath)"
            banner.textColor = .systemOrange
        }
        addRow(banner)

        addRow(sectionLabel("Найдены на компьютере"))
        if found.isEmpty {
            let empty = NSTextField(labelWithString: "Модели ggml-*.bin не найдены.")
            empty.font = .systemFont(ofSize: 11)
            empty.textColor = .secondaryLabelColor
            addRow(empty)
        } else {
            for model in found { addRow(modelRow(model)) }
        }

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let addFile = NSButton(title: "Добавить файл…", target: self, action: #selector(addModelFile))
        addFile.bezelStyle = .rounded
        let addFolder = NSButton(title: "Добавить папку…", target: self, action: #selector(addModelFolder))
        addFolder.bezelStyle = .rounded
        buttons.addArrangedSubview(addFile)
        buttons.addArrangedSubview(addFolder)
        addRow(buttons)

        let missing = WhisperModelCatalog.models.filter { model in
            !found.contains(where: { $0.fileName == model.fileName })
        }
        if !missing.isEmpty {
            addRow(sectionLabel("Скачать"))
            for model in missing { addRow(downloadRow(model)) }
        }

        addRow(sectionLabel("Хранилище"))
        modelsDiskLabel = NSTextField(labelWithString: "")
        modelsDiskLabel.font = .systemFont(ofSize: 11)
        modelsDiskLabel.textColor = .secondaryLabelColor
        updateDiskLabel()
        addRow(modelsDiskLabel)
    }

    private func addRow(_ view: NSView) {
        modelsStack.addArrangedSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: modelsStack.widthAnchor, constant: -32).isActive = true
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12, weight: .bold)
        field.textColor = .secondaryLabelColor
        return field
    }

    private func modelRow(_ model: WhisperModelFile) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let radio = NSButton(radioButtonWithTitle: "", target: self, action: #selector(selectModel(_:)))
        radio.identifier = NSUserInterfaceItemIdentifier(model.path)
        radio.state = (model.path == selectedModelPath) ? .on : .off
        radio.setContentHuggingPriority(.required, for: .horizontal)

        let title: NSTextField
        if let catalog = WhisperModelCatalog.models.first(where: { $0.fileName == model.fileName }) {
            title = NSTextField(labelWithString: catalog.title)
        } else {
            title = NSTextField(labelWithString: model.fileName)
        }
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        let subtitle = NSTextField(labelWithString: "\(model.sizeText) · \(model.directory)")
        subtitle.font = .systemFont(ofSize: 10)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingMiddle

        let text = NSStackView(views: [title, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let reveal = NSButton(title: "Показать", target: self, action: #selector(revealModel(_:)))
        reveal.bezelStyle = .inline
        reveal.identifier = NSUserInterfaceItemIdentifier(model.path)

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        row.addArrangedSubview(radio)
        row.addArrangedSubview(text)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(reveal)

        if model.isManaged {
            let delete = NSButton(title: "Удалить", target: self, action: #selector(deleteModel(_:)))
            delete.bezelStyle = .inline
            delete.identifier = NSUserInterfaceItemIdentifier(model.path)
            row.addArrangedSubview(delete)
        } else {
            let hide = NSButton(title: "Скрыть", target: self, action: #selector(hideModel(_:)))
            hide.bezelStyle = .inline
            hide.identifier = NSUserInterfaceItemIdentifier(model.path)
            row.addArrangedSubview(hide)
        }
        return row
    }

    private func downloadRow(_ model: WhisperModel) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 4

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10

        let title = NSTextField(labelWithString: model.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let subtitle = NSTextField(labelWithString: model.sizeText + (model.recommended ? " · рекомендуется" : ""))
        subtitle.font = .systemFont(ofSize: 10)
        subtitle.textColor = .secondaryLabelColor

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let percent = NSTextField(labelWithString: "")
        percent.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        percent.textColor = .secondaryLabelColor
        percent.isHidden = downloads[model.id] == nil
        if let value = downloadProgress[model.id] {
            percent.stringValue = "\(Int(value * 100))%"
        }

        let button = NSButton(title: downloads[model.id] == nil ? "Скачать" : "Отмена",
                              target: self, action: #selector(downloadModel(_:)))
        button.bezelStyle = .rounded
        button.identifier = NSUserInterfaceItemIdentifier(model.id)

        header.addArrangedSubview(title)
        header.addArrangedSubview(subtitle)
        header.addArrangedSubview(spacer)
        header.addArrangedSubview(percent)
        header.addArrangedSubview(button)

        let note = NSTextField(wrappingLabelWithString: model.note)
        note.font = .systemFont(ofSize: 10)
        note.textColor = .secondaryLabelColor

        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.doubleValue = downloadProgress[model.id] ?? 0
        bar.isHidden = downloads[model.id] == nil
        bar.heightAnchor.constraint(equalToConstant: 6).isActive = true

        container.addArrangedSubview(header)
        container.addArrangedSubview(note)
        container.addArrangedSubview(bar)

        header.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        note.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        bar.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true

        downloadBars[model.id] = bar
        downloadPercents[model.id] = percent
        return container
    }

    @objc private func downloadModel(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let model = WhisperModelCatalog.models.first(where: { $0.id == id }) else { return }

        if let active = downloads[id] {
            active.cancel()
            downloads[id] = nil
            downloadProgress[id] = nil
            refreshModels()
            return
        }

        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        let free = (attrs?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        if free < model.sizeBytes + 200 * 1024 * 1024 {
            let alert = NSAlert()
            alert.messageText = "Недостаточно места"
            alert.informativeText = "Для загрузки нужно \(model.sizeText) плюс запас 200 МБ."
            alert.runModal()
            return
        }

        let downloader = ModelDownloader(model: model)
        downloads[id] = downloader
        downloadProgress[id] = 0

        downloader.onProgress = { [weak self] value in
            guard let self else { return }
            self.downloadProgress[id] = value
            self.downloadBars[id]?.doubleValue = value
            self.downloadPercents[id]?.stringValue = "\(Int(value * 100))%"
            self.downloadPercents[id]?.isHidden = false
        }
        downloader.onFinish = { [weak self] result in
            guard let self else { return }
            self.downloads[id] = nil
            self.downloadProgress[id] = nil
            switch result {
            case .success(let url):
                if self.selectedModelPath.isEmpty { self.selectedModelPath = url.path }
                self.refreshModels()
                Log.write("model: скачана \(url.lastPathComponent)")
            case .failure(let error):
                self.refreshModels()
                Log.write("model: ошибка загрузки \(model.id): \(error.localizedDescription)")
                let alert = NSAlert()
                alert.messageText = "Не удалось скачать модель"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
        downloader.start()
        refreshModels()
    }

    private func updateDiskLabel() {
        guard let modelsDiskLabel else { return }
        let fm = FileManager.default
        let managed = WhisperModelStore.foundModels()
            .filter { $0.isManaged }
            .reduce(Int64(0)) { $0 + $1.sizeBytes }
        let attrs = try? fm.attributesOfFileSystem(forPath: NSHomeDirectory())
        let free = (attrs?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        modelsDiskLabel.stringValue =
            "Скачанные приложением: \(WhisperSize.text(managed))"
            + " · свободно: \(WhisperSize.text(free))"
    }

    @objc private func selectModel(_ sender: NSButton) {
        selectedModelPath = sender.identifier?.rawValue ?? ""
        refreshModels()
    }

    @objc private func revealModel(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc private func deleteModel(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue, WhisperModelStore.isManaged(path: path) else { return }
        let alert = NSAlert()
        alert.messageText = "Удалить модель?"
        alert.informativeText = "Файл будет удалён с диска. Это действие нельзя отменить."
        alert.addButton(withTitle: "Удалить")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? FileManager.default.removeItem(atPath: path)
        if selectedModelPath == path { selectedModelPath = "" }
        refreshModels()
    }

    @objc private func hideModel(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        if !hiddenModelPaths.contains(path) { hiddenModelPaths.append(path) }
        if selectedModelPath == path { selectedModelPath = "" }
        refreshModels()
    }

    @objc private func addModelFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "bin") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard WhisperModelStore.isWhisperModel(at: url) else {
            let alert = NSAlert()
            alert.messageText = "Это не модель Whisper"
            alert.informativeText = "Нужен файл ggml-*.bin от whisper.cpp."
            alert.runModal()
            return
        }
        let dir = url.deletingLastPathComponent().path
        if !modelDirs.contains(dir) { modelDirs.append(dir) }
        hiddenModelPaths.removeAll { $0 == url.standardized.path }
        selectedModelPath = url.standardized.path
        refreshModels()
    }

    @objc private func addModelFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !modelDirs.contains(url.path) { modelDirs.append(url.path) }
        refreshModels()
    }

    // MARK: - Prompt

    private func buildPrompt() -> NSView {
        let view = NSView()
        let fixLabel = label("Промпт для исправления текста  (⌥Space)", bold: true)
        let fixHint = label("«Сбросить» вернёт встроенный текст. Изменения применяются после «Сохранить».")

        let fixScroll = makeScroll(fixText)

        fixLabel.translatesAutoresizingMaskIntoConstraints = false
        fixHint.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(fixLabel)
        view.addSubview(fixScroll)
        view.addSubview(fixHint)

        NSLayoutConstraint.activate([
            fixLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            fixLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            fixLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            fixScroll.topAnchor.constraint(equalTo: fixLabel.bottomAnchor, constant: 6),
            fixScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            fixScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            fixScroll.heightAnchor.constraint(equalToConstant: 330),

            fixHint.topAnchor.constraint(equalTo: fixScroll.bottomAnchor, constant: 6),
            fixHint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            fixHint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
        ])

        return view
    }

    private func label(_ text: String, bold: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = bold ? .boldSystemFont(ofSize: 13) : .systemFont(ofSize: 11)
        field.textColor = bold ? .labelColor : .secondaryLabelColor
        return field
    }

    private func makeScroll(_ textView: NSTextView) -> NSScrollView {
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.documentView = textView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }

    // MARK: - Hotkeys

    private func buildHotkeys() -> NSView {
        let view = NSView()
        let toggleLabel = label("Диктовка")
        let hint = label("Кликните по сочетанию и нажмите новое. Esc — отмена.")
        let note = label("Нужен хотя бы один модификатор из ⌃ / ⌥ / ⌘.")

        toggleHotkeyButton = NSButton(title: toggleHotkey.display, target: self, action: #selector(captureToggle))
        toggleHotkeyButton.bezelStyle = .rounded

        let views: [NSView] = [toggleLabel, hint, note, toggleHotkeyButton]
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }

        NSLayoutConstraint.activate([
            toggleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            toggleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            toggleHotkeyButton.centerYAnchor.constraint(equalTo: toggleLabel.centerYAnchor),
            toggleHotkeyButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            toggleHotkeyButton.widthAnchor.constraint(equalToConstant: 190),

            hint.topAnchor.constraint(equalTo: toggleLabel.bottomAnchor, constant: 22),
            hint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            note.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 4),
            note.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
        ])

        return view
    }

    // MARK: - Горячие клавиши

    @objc private func captureToggle() { startCapture(button: toggleHotkeyButton) }

    private func startCapture(button: NSButton) {
        stopCapture()
        captureTarget = button
        button.title = "Нажмите сочетание…"
        onCaptureStateChanged?(true)
        captureMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleCapture(event)
            return nil
        }
    }

    private func stopCapture() {
        if let monitor = captureMonitor { NSEvent.removeMonitor(monitor) }
        captureMonitor = nil
        if let button = captureTarget {
            button.title = toggleHotkey.display
        }
        captureTarget = nil
        onCaptureStateChanged?(false)
    }

    private func handleCapture(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if event.keyCode == UInt16(kVK_Escape) && flags.isEmpty {
            stopCapture()
            return
        }

        let mods = carbonModifiers(flags)
        if mods & (UInt32(controlKey) | UInt32(optionKey) | UInt32(cmdKey)) == 0 {
            NSSound.beep()
            return
        }

        let setting = HotKeySetting(keyCode: UInt32(event.keyCode),
                                    modifiers: mods,
                                    display: displayString(keyCode: event.keyCode,
                                                           flags: flags,
                                                           characters: event.charactersIgnoringModifiers))
        if captureTarget === toggleHotkeyButton {
            toggleHotkey = setting
        }
        stopCapture()
    }

    private func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        return mods
    }

    private func displayString(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) -> String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }

        switch Int(keyCode) {
        case kVK_Space: text += "Space"
        case kVK_Return: text += "Return"
        case kVK_Tab: text += "Tab"
        case kVK_Delete: text += "Delete"
        case kVK_ForwardDelete: text += "FwdDel"
        case kVK_LeftArrow: text += "←"
        case kVK_RightArrow: text += "→"
        case kVK_UpArrow: text += "↑"
        case kVK_DownArrow: text += "↓"
        case kVK_Home: text += "Home"
        case kVK_End: text += "End"
        case kVK_PageUp: text += "PgUp"
        case kVK_PageDown: text += "PgDn"
        default:
            if let chars = characters?.uppercased(), !chars.isEmpty, chars != " " {
                text += chars
            } else {
                text += "Key\(keyCode)"
            }
        }
        return text
    }

    // MARK: - Диагностика

    private func refreshDiagnostics() {
        let ok = AXIsProcessTrusted()
        accessLabel.stringValue = ok ? "Accessibility: ✓ разрешено" : "Accessibility: ⚠️ нет доступа"
        accessLabel.textColor = ok ? .systemGreen : .systemOrange
        accessButton.isHidden = ok

        let settings = SettingsStore.load()
        for (index, dependency) in Dependency.allCases.enumerated() where index < depLabels.count {
            if dependency == .opencode && !settings.useOpenCode {
                depLabels[index].stringValue = "– OpenCode CLI (не используется)"
                depLabels[index].textColor = .secondaryLabelColor
                continue
            }

            let available = dependency.isOK()
            depLabels[index].stringValue = available
                ? "✓ \(dependency.title)"
                : "⚠️ \(dependency.title) — \(dependency.expected)"
            depLabels[index].textColor = available ? .systemGreen : .systemOrange
        }
    }

    @objc private func openAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func loadValues() {
        let settings = SettingsStore.load()
        fixText.string = settings.promptFix.isEmpty ? DefaultPrompts.fix : settings.promptFix

        languagePopup.selectItem(at: languages.firstIndex(of: settings.language) ?? 0)
        providerField.stringValue = settings.provider
        modelField.stringValue = settings.model
        baseURLField.stringValue = settings.baseURL
        useOpenCodeCheck.state = settings.useOpenCode ? .on : .off
        restoreCheck.state = settings.restoreClipboard ? .on : .off
        hudCheck.state = settings.showHUD ? .on : .off

        toggleHotkey = settings.hotkeyToggle
        toggleHotkeyButton.title = toggleHotkey.display

        modelDirs = settings.whisperModelDirs
        hiddenModelPaths = settings.hiddenModelPaths
        selectedModelPath = settings.whisperModelPath
        if selectedModelPath.isEmpty,
           let auto = WhisperModelStore.activeModel(settings: settings) {
            selectedModelPath = auto.path
        }
        refreshModels()
    }

    @objc private func resetDefaults() {
        switch tabView.selectedTabViewItem?.identifier as? String {
        case "prompt":
            fixText.string = DefaultPrompts.fix
        case "hotkeys":
            toggleHotkey = HotKeySetting()
            toggleHotkeyButton.title = toggleHotkey.display
        case "ai":
            providerField.stringValue = "deepseek"
            modelField.stringValue = "deepseek-flash"
            baseURLField.stringValue = ""
            useOpenCodeCheck.state = .on
        case "models":
            modelDirs = []
            hiddenModelPaths = []
            selectedModelPath = WhisperModelStore.autoSelect(
                from: WhisperModelStore.foundModels())?.path ?? ""
            refreshModels()
        default:
            languagePopup.selectItem(at: 0)
            restoreCheck.state = .off
            hudCheck.state = .on
        }
    }

    @objc private func cancel() {
        window?.close()
    }

    @objc private func saveSettings() {
        var settings = SettingsStore.load()
        settings.promptFix = fixText.string
        settings.language = languages[max(0, languagePopup.indexOfSelectedItem)]
        settings.provider = providerField.stringValue.trimmingCharacters(in: .whitespaces)
        settings.model = modelField.stringValue.trimmingCharacters(in: .whitespaces)
        settings.baseURL = baseURLField.stringValue.trimmingCharacters(in: .whitespaces)
        settings.useOpenCode = useOpenCodeCheck.state == .on
        settings.restoreClipboard = restoreCheck.state == .on
        settings.showHUD = hudCheck.state == .on
        settings.hotkeyToggle = toggleHotkey
        settings.whisperModelPath = selectedModelPath
        settings.whisperModelDirs = modelDirs
        settings.hiddenModelPaths = hiddenModelPaths

        if !settings.baseURL.isEmpty,
           !settings.baseURL.lowercased().hasPrefix("http://"),
           !settings.baseURL.lowercased().hasPrefix("https://") {
            let alert = NSAlert()
            alert.messageText = "Некорректный базовый URL"
            alert.informativeText = "URL должен начинаться с http:// или https://"
            alert.runModal()
            return
        }

        SettingsStore.save(settings)
        onSettingsSaved?()
        Log.write("settings saved")
        window?.close()
    }
}

/// Документ NSScrollView с началом координат сверху — иначе контент
/// прижимается к нижнему краю окна.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
