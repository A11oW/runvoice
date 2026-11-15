import AppKit

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
var checks = 0
func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    precondition(value(), message)
}
func spin(_ duration: TimeInterval = 0.03) {
    RunLoop.main.run(until: Date().addingTimeInterval(duration))
}
func waitFor(_ message: String, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(4)
    while !condition(), Date() < deadline { spin() }
    expect(condition(), message)
}
func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(descendants)
}

func runChecks() throws {
    var initial = Settings()
    initial.providers = []
    initial.dictationProviderID = nil
    initial.improveProviderID = nil
    initial.fluidModel = .nemotron
    initial.language = "auto"
    SettingsStore.save(initial)
    let controller = SettingsWindow()
    controller.show()
    controller.selectTab("models")
    let root = controller.window!.contentView!
    func views() -> [NSView] { descendants(root) }
    func labels() -> [String] { views().compactMap { ($0 as? NSTextField)?.stringValue } }
    func button(_ predicate: (NSButton) -> Bool) -> NSButton {
        views().compactMap { $0 as? NSButton }.first(where: predicate)!
    }
    let technology = views().compactMap { $0 as? NSPopUpButton }
        .first { $0.accessibilityLabel() == "Технология распознавания" }!
    func selectTechnology(_ index: Int) {
        technology.selectItem(at: index)
        application.sendAction(technology.action!, to: technology.target, from: technology)
        spin()
    }
    expect(technology.numberOfItems == 2, "Технология содержит библиотеки, а не имена моделей")
    let whisperButtons = views().compactMap { $0 as? NSButton }.filter { $0.title == "Скачать" }
    expect(whisperButtons.count == WhisperModelCatalog.models.count, "Все модели Whisper видны сразу, без раскрытия скрытого каталога")
    expect(whisperButtons.contains { $0.identifier?.rawValue == "medium-q5_0" }, "Средняя квантованная модель доступна по кнопке")
    expect(!views().contains { ($0 as? NSButton)?.title == FluidModel.parakeet.title }, "В каталоге Whisper нет моделей FluidAudio")
    expect(labels().contains("Экспериментальная"), "Донастройки Whisper явно помечены как экспериментальные")
    if !RecognitionTechnology.fluidAudio.isSupported {
        expect(technology.item(at: 1)?.isEnabled == false, "На Intel FluidAudio недоступен")
        controller.window?.orderOut(nil)
        return
    }
    func install(_ model: FluidModel) throws {
        let root = FluidModelStore.directory(for: model)
        let validated = root.appendingPathComponent("validated-model")
        try FileManager.default.createDirectory(at: validated, withIntermediateDirectories: true)
        try validated.path.write(to: root.appendingPathComponent("installed-model"), atomically: true, encoding: .utf8)
    }
    try install(.nemotron)
    selectTechnology(1)
    for model in FluidModel.allCases {
        expect(views().contains { ($0 as? NSButton)?.title == model.title }, "Все модели FluidAudio показаны в совместимом каталоге")
    }
    expect(button { $0.title == FluidModel.nemotron.title }.state == .on, "Переключение технологии восстанавливает выбранный Nemotron")
    let unavailable = button { $0.title == FluidModel.parakeet.title }
    expect(!unavailable.isEnabled, "Нескачанную модель нельзя выбрать до успешной проверки")
    application.sendAction(unavailable.action!, to: unavailable.target, from: unavailable)
    expect(button { $0.title == FluidModel.nemotron.title }.state == .on, "Контроллер отклоняет выбор недоступной модели даже при прямом вызове действия")
    expect(!labels().contains("Найдены на компьютере"), "Основной каталог Whisper скрыт при FluidAudio")
    expect(labels().contains { $0.contains("Язык распознавания") }, "Общие параметры доступны для FluidAudio")
    let marker = FluidModelStore.directory(for: .nemotron).appendingPathComponent("installed-model")
    try FileManager.default.removeItem(at: marker)
    button { $0.title == "Сохранить" }.performClick(nil)
    expect(SettingsStore.load().recognitionTechnology == .whisper, "Новая технология без готовой модели не сохраняется")
    expect(labels().contains { $0.contains("Сначала скачайте и проверьте") }, "Недоступная модель объясняется в окне без блокирующего диалога")
    try install(.nemotron)
    button { $0.title == FluidModel.nemotron.title }.performClick(nil)

    let first = WhisperModelStore.modelsDirectory.appendingPathComponent("ggml-tiny.bin")
    let secondModel = WhisperModelCatalog.models.first { $0.experimental }!
    let second = WhisperModelStore.modelsDirectory.appendingPathComponent(secondModel.fileName)
    let fakeModel = Data("lmgg".utf8) + Data(count: 1_000_001)
    try fakeModel.write(to: first)
    try fakeModel.write(to: second)
    func openBackup() -> NSView {
        button { $0.title == "Настроить резервный Whisper…" }.performClick(nil)
        return controller.window!.attachedSheet!.contentView!
    }
    func sheetButton(_ sheet: NSView, _ predicate: (NSButton) -> Bool) -> NSButton {
        descendants(sheet).compactMap { $0 as? NSButton }.first(where: predicate)!
    }
    let cancelledSheet = openBackup()
    expect(!labels().contains("Найдены на компьютере"), "Открытие резерва не добавляет Whisper в основной каталог FluidAudio")
    expect(!descendants(cancelledSheet).contains { ($0 as? NSButton)?.title == FluidModel.nemotron.title }, "В отдельном резервном окне только модели Whisper")
    sheetButton(cancelledSheet) { $0.identifier?.rawValue == first.path && $0.title.isEmpty }.performClick(nil)
    sheetButton(cancelledSheet) { $0.title == "Отмена" }.performClick(nil)
    waitFor("Резервное окно закрывается после отмены") { controller.window!.attachedSheet == nil }
    expect(cancelledSheet.window?.isVisible != true, "Отмена убирает панель с экрана")
    spin(0.2)
    let acceptedSheet = openBackup()
    expect(sheetButton(acceptedSheet) { $0.identifier?.rawValue == first.path && $0.title.isEmpty }.state == .off,
           "Отмена резервного окна откатывает черновой выбор")
    sheetButton(acceptedSheet) { $0.identifier?.rawValue == second.path && $0.title.isEmpty }.performClick(nil)
    expect(descendants(acceptedSheet).contains { ($0 as? NSButton)?.title.contains("экспериментальная") == true },
           "У установленного экспериментального Whisper сохраняется пометка")
    sheetButton(acceptedSheet) { $0.title == "Готово" }.performClick(nil)
    waitFor("Готово закрывает резервное окно") { controller.window!.attachedSheet == nil }
    expect(acceptedSheet.window?.isVisible != true, "Готово убирает панель с экрана")
    spin(0.2)
    expect(SettingsStore.load().whisperModelPath.isEmpty, "Готово сохраняет резерв в черновике, до основного Сохранить")
    selectTechnology(0)
    selectTechnology(1)
    expect(button { $0.title == FluidModel.nemotron.title }.state == .on, "Выбор модели сохраняется при смене технологии")
    expect(SettingsStore.load().recognitionTechnology == .whisper, "Черновые переключения не сохраняются автоматически")

    // Настоящий дочерний процесс проверяет поведение UI при загрузке и отмене.
    let helper = Bundle.main.resourceURL!.appendingPathComponent("RunvoiceASR")
    try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
    try """
    #!/usr/bin/env python3
    import sys, json, time, pathlib
    root = pathlib.Path(sys.argv[2])
    print('RUNVOICE_ASR ' + json.dumps({'event': 'progress', 'progress': 0.5}), flush=True)
    time.sleep(0.4)
    model = root / 'validated-model'
    model.mkdir(parents=True, exist_ok=True)
    (root / 'installed-model').write_text(str(model))
    print('RUNVOICE_ASR ' + json.dumps({'event': 'installed'}), flush=True)
    """.write(to: helper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    button { $0.identifier?.rawValue == FluidModel.parakeet.rawValue && $0.title == "Скачать" }.performClick(nil)
    let progressDeadline = Date().addingTimeInterval(4)
    while !labels().contains(where: { $0.contains("50%") }), Date() < progressDeadline { spin() }
    if !labels().contains(where: { $0.contains("50%") }) {
        FileHandle.standardError.write(Data("Download diagnostics: \(labels()) helper=\(helper.path) executable=\(FileManager.default.isExecutableFile(atPath: helper.path))\n".utf8))
    }
    expect(labels().contains { $0.contains("50%") }, "Прогресс загрузки виден в строке модели")
    button { $0.title == "Отменить загрузку" }.performClick(nil)
    spin(0.5)
    expect(!FluidModelStore.installed(.parakeet), "Отмена не создаёт маркер установки")
    button { $0.identifier?.rawValue == FluidModel.parakeet.rawValue && $0.title == "Скачать" }.performClick(nil)
    selectTechnology(0)
    waitFor("Фоновая загрузка заканчивается при открытом каталоге Whisper") { FluidModelStore.installed(.parakeet) }
    selectTechnology(1)
    expect(button { $0.title == FluidModel.nemotron.title }.state == .on, "Скачивание другой модели не меняет выбор")
    expect(button { $0.title == FluidModel.parakeet.title }.isEnabled, "После успешной загрузки выбор модели становится доступен")
    button { $0.title == FluidModel.parakeet.title }.performClick(nil)
    button { $0.title == "Сохранить" }.performClick(nil)
    let saved = SettingsStore.load()
    expect(saved.recognitionTechnology == .fluidAudio && saved.fluidModel == .parakeet, "Сохранить применяет технологию и модель")
    expect(saved.language == "auto", "Перерисовка каталога сохраняет выбранный язык")
    expect(saved.whisperModelPath == second.path, "Основное Сохранить применяет выбранный резерв, включая явный экспериментальный выбор")
    controller.window?.orderOut(nil)
}

// Вложенный RunLoop должен обслуживать IPC, поэтому стартуем из timer,
// а не удерживаем выполняющийся блок serial main queue.
let startTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
    do {
        try runChecks()
        print("OK: \(checks) проверок последовательного выбора моделей, загрузки и сохранения")
        application.terminate(nil)
    } catch {
        FileHandle.standardError.write(Data("Recognition tests: \(error)\n".utf8))
        exit(1)
    }
}
application.run()
