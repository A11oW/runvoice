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
    try testAudioSample()
    var initial = Settings()
    initial.providers = []
    initial.dictationProviderID = nil
    initial.improveProviderID = nil
    initial.fluidModel = .nemotron
    initial.language = "auto"
    SettingsStore.save(initial)
    let isolation = SettingsWindow()
    var commonSaves = 0, apiSaves = 0
    isolation.onSettingsSaved = { commonSaves += 1 }
    isolation.onAPISettingsSaved = { apiSaves += 1 }
    isolation.show(); isolation.selectTab("api")
    let isolationViews = descendants(isolation.window!.contentView!)
    let filter = isolationViews.compactMap { $0 as? NSSwitch }.first { $0.identifier?.rawValue == "api-audio-filter" }!
    let dictionary = isolationViews.compactMap { $0 as? NSSwitch }.first { $0.identifier?.rawValue == "api-use-vocabulary" }!
    let threshold = isolationViews.compactMap { $0 as? NSSlider }.first { $0.identifier?.rawValue == "api-minimum-dbfs" }!
    expect(filter.state == .on && dictionary.state == .on && threshold.doubleValue == -55, "Фильтр и словарь API включены, порог -55")
    filter.performClick(nil); dictionary.performClick(nil); threshold.doubleValue = -40
    expect(!threshold.isEnabled, "Выключение фильтра отключает ползунок")
    isolationViews.compactMap { $0 as? NSButton }.first { $0.title == "Сохранить" }!.performClick(nil)
    let apiOnlySaved = SettingsStore.load()
    expect(commonSaves == 0 && apiSaves == 1, "API-only сохранение не вызывает обновление хоткеев, HUD и прогрева диктовки")
    expect(!apiOnlySaved.differsOutsideAPI(from: initial) && !apiOnlySaved.apiUseVocabulary && !apiOnlySaved.apiAudioFilterEnabled && apiOnlySaved.apiMinimumSpeechDbfs == -40, "API-only сохранение сохраняет остальные поля без нормализации")
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
    controller.selectTab("general")
    expect(views().contains { $0.identifier?.rawValue == "check-updates" }, "В Основных доступна ручная проверка обновлений")
    expect(labels().contains { $0.contains("Проверка при запуске и раз в сутки") }, "Основные показывают состояние механизма обновлений без сетевого запуска в тестах")
    expect(!views().contains { $0.identifier?.rawValue == "record-audio-sample" }, "В разделе Основные нет записи сэмпла")
    let sidebarSearch = views().compactMap { $0 as? NSSearchField }.first!
    func filterSidebar(_ text: String) {
        sidebarSearch.stringValue = text
        application.sendAction(sidebarSearch.action!, to: sidebarSearch.target, from: sidebarSearch)
    }
    filterSidebar("словарь")
    expect(views().compactMap { $0 as? SettingsSidebarItem }.filter { !$0.isHidden }.map(\.title) == ["Словарь"],
           "Поиск оставляет только совпадающий раздел")
    filterSidebar("zzz")
    let emptySearch = views().compactMap { $0 as? NSTextField }.first { $0.stringValue == "Ничего не найдено" }
    expect(emptySearch?.isHidden == false, "Поиск без совпадений показывает пустое состояние")
    filterSidebar("")
    expect(emptySearch?.isHidden == true, "Очистка поиска скрывает пустое состояние")
    expect(views().compactMap { $0 as? SettingsSidebarItem }.allSatisfy { !$0.isHidden },
           "Очистка поиска возвращает все разделы")
    let hotkeysItem = views().compactMap { $0 as? SettingsSidebarItem }.first { $0.pageID == "hotkeys" }!
    hotkeysItem.performClick(nil)
    expect(views().contains { $0.identifier?.rawValue == "pause-recording-on-space" },
           "Клик по пункту сайдбара открывает раздел")
    let draftPause = views().compactMap { $0 as? NSSwitch }
        .first { $0.identifier?.rawValue == "pause-recording-on-space" }!
    draftPause.state = .off
    views().compactMap { $0 as? SettingsSidebarItem }.first { $0.pageID == "general" }!.performClick(nil)
    hotkeysItem.performClick(nil)
    expect(draftPause.state == .off, "Клик по сайдбару сохраняет черновик")
    draftPause.state = .on
    controller.selectTab("general")
    let version = views().compactMap { $0 as? SampleAccessLabel }.first!
    for count in 1...3 {
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: controller.window!.windowNumber,
                                      context: nil, eventNumber: count, clickCount: count, pressure: 1)!
        version.mouseDown(with: event)
        expect(controller.window!.attachedSheet == nil, "Первые три клика по версии не открывают скрытую модалку")
    }
    let fourth = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
                                   timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: controller.window!.windowNumber,
                                   context: nil, eventNumber: 4, clickCount: 4, pressure: 1)!
    version.mouseDown(with: fourth)
    waitFor("Четвёртый клик открывает модальное окно") { controller.window!.attachedSheet?.title == "Аудиосэмплы" }
    let sampleSheet = controller.window!.attachedSheet!
    version.mouseDown(with: fourth)
    expect(controller.window!.attachedSheet === sampleSheet, "Повторное открытие не дублирует модалку")
    let sampleButtons = descendants(sampleSheet.contentView!).compactMap { $0 as? NSButton }
    expect(["Запись сэмпла", "Папка сэмплов", "Выбрать папку сэмпла…"].allSatisfy { title in sampleButtons.contains { $0.title == title } },
           "Скрытая модалка содержит все три действия с сэмплами")
    sampleButtons.first { $0.title == "Закрыть" }!.performClick(nil)
    waitFor("Скрытая модалка закрыта") { controller.window!.attachedSheet == nil }
    controller.selectTab("api")
    let apiEnabled = views().compactMap { $0 as? NSSwitch }.first { $0.identifier?.rawValue == "api-enabled" }!
    let apiImprove = views().compactMap { $0 as? NSSwitch }.first { $0.identifier?.rawValue == "api-improve-text" }!
    let apiPort = views().compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "api-port" }!
    expect(apiEnabled.state == .off && apiImprove.state == .off && apiPort.stringValue == "8790",
           "Раздел API содержит независимые выключенные переключатели и порт 8790")
    root.layoutSubtreeIfNeeded()
    expect(apiEnabled.convert(apiEnabled.bounds, to: root).intersects(root.bounds) && apiEnabled.window != nil, "Элементы API видны в области раздела после раскладки прокрутки")
    expect(labels().contains { $0.contains("127.0.0.1:8790/runvoice/v1/audio/transcriptions") }, "Раздел показывает полный совместимый адрес")
    let apiModel = views().compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "api-recognition-model" }!
    expect(apiModel.titleOfSelectedItem == "Как в приложении", "Модель API наследуется по умолчанию")
    expect(!apiModel.itemTitles.contains { $0.hasPrefix("FluidAudio") }, "Нескачанные FluidAudio отсутствуют в списке API")
    controller.selectTab("hotkeys")
    let pauseOnSpace = views().compactMap { $0 as? NSSwitch }
        .first { $0.identifier?.rawValue == "pause-recording-on-space" }!
    let pauseTitle = (pauseOnSpace.accessibilityTitleUIElement() as? NSTextField)?.stringValue
    expect(pauseOnSpace.state == .on && pauseTitle == "Пауза диктовки по пробелу",
           "Пауза по пробелу доступна в разделе Хоткеи и включена по умолчанию")
    expect(labels().contains { $0.contains("на паузе Enter") }
        && labels().contains { $0.contains("на паузе Esc") }, "Enter и Esc объясняют действие на паузе")
    pauseOnSpace.state = .off
    controller.selectTab("models")
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
    let headings = ["Движок", "Модель"]
    func expectSectionOrder() {
        expect(labels().filter { headings.contains($0) } == headings,
               "Блоки идут в порядке: движок, модель")
    }
    expectSectionOrder()
    expect(labels().contains { $0.hasPrefix("Скачивание (") },
           "В каталоге Whisper есть отдельный блок скачивания")
    expect(labels().contains { $0.contains("Язык — подсказка модели") }, "Whisper объясняет язык как подсказку")
    let language = views().compactMap { $0 as? NSPopUpButton }
        .first { $0.accessibilityLabel() == "Язык распознавания" }!
    let preview = views().compactMap { $0 as? RecognitionPreviewControls }.first!
    language.selectItem(at: 0)
    preview.options = RecognitionPreview(enabled: false, lineCount: 7)
    controller.selectTab("dictionary")
    let vocabulary = views().compactMap { $0 as? SpeechVocabularyEditor }.first!
    expect(labels().contains { $0.contains("Whisper —") && $0.contains("Nemotron —")
        && $0.contains("Parakeet и Phonon —") && $0.contains("при отключённой AI-правке")
        && $0.contains("для всех моделей") }, "Словарь объясняет три способа применения и общий этап AI-правки")
    vocabulary.input.string = "Cypress, shared"
    controller.selectTab("models")
    expect(vocabulary.input.string == "Cypress, shared", "Переход между разделами сохраняет незавершённый ввод словаря")
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
    expectSectionOrder()
    expect(labels().contains { $0.contains("подсказку потоковой модели") }, "Nemotron имеет отдельное пояснение языка")
    expect(language.indexOfSelectedItem == 0 && preview.options == RecognitionPreview(enabled: false, lineCount: 7),
           "Смена технологии сохраняет язык и отключённый предпросмотр с выбранным числом строк")
    expect(vocabulary.input.string == "Cypress, shared", "Смена технологии сохраняет незавершённый словарь")
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
    expect(labels().contains { $0.contains("Язык — подсказка модели") }, "Возврат к Whisper восстанавливает его пояснение")
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
    vocabulary.input.string = "Vitest"
    for model in FluidModel.allCases {
        try install(model)
        button { $0.title == model.title }.performClick(nil)
        expectSectionOrder()
        expect(labels().contains { model == .nemotron ? $0.contains("подсказку потоковой модели")
            : $0.contains("ограничивает алфавит") && $0.contains("English — латиница")
                && $0.contains("снять это ограничение") }, "Пояснение языка соответствует выбранной модели \(model.rawValue)")
        expect(language.indexOfSelectedItem == 0 && preview.options == RecognitionPreview(enabled: false, lineCount: 7),
               "Рекомендация Авто не меняет выбранный Русский или параметры предпросмотра")
        expect(vocabulary.input.string == "Vitest", "Смена модели не очищает черновик словаря")
    }
    language.selectItem(at: 2)
    button { $0.title == FluidModel.parakeet.title }.performClick(nil)
    controller.selectTab("api")
    expect(apiModel.itemTitles.contains("FluidAudio · " + FluidModel.nemotron.title), "Список API обновляется после установки моделей")
    apiModel.selectItem(withTitle: "FluidAudio · " + FluidModel.nemotron.title)
    application.sendAction(apiModel.action!, to: apiModel.target, from: apiModel)
    expect(SettingsStore.load().apiRecognitionModel == .application, "Черновой выбор модели API не сохраняется автоматически")
    controller.selectTab("models")
    button { $0.title == "Сохранить" }.performClick(nil)
    let saved = SettingsStore.load()
    expect(saved.recognitionTechnology == .fluidAudio && saved.fluidModel == .parakeet, "Сохранить применяет технологию и модель")
    expect(saved.apiRecognitionModel == .fluidAudio(.nemotron), "Сохранение записывает независимую модель API")
    expect(saved.language == "auto", "Перерисовка каталога сохраняет выбранный язык")
    expect(!saved.previewEnabled && saved.previewLineCount == 7, "Сохранить записывает параметры отдельного блока предпросмотра")
    expect(saved.speechVocabulary == ["Cypress", "shared", "Vitest"], "Сохранение включает прежние термины и незавершённый ввод")
    expect(saved.whisperModelPath == second.path, "Основное Сохранить применяет выбранный резерв, включая явный экспериментальный выбор")
    expect(!saved.pauseRecordingOnSpace, "Сохранение настроек записывает отключение паузы, не теряя черновик при смене вкладок")
    controller.window?.orderOut(nil)
    let reopened = SettingsWindow()
    reopened.show()
    reopened.selectTab("hotkeys")
    let loadedPause = descendants(reopened.window!.contentView!).compactMap { $0 as? NSSwitch }
        .first { $0.identifier?.rawValue == "pause-recording-on-space" }!
    expect(loadedPause.state == .off, "Повторное открытие Хоткеев восстанавливает отключённую паузу")
    reopened.selectTab("api")
    let restoredAPIModel = descendants(reopened.window!.contentView!).compactMap { $0 as? NSPopUpButton }
        .first { $0.identifier?.rawValue == "api-recognition-model" }!
    expect(restoredAPIModel.titleOfSelectedItem == "FluidAudio · " + FluidModel.nemotron.title,
           "Повторное открытие API восстанавливает отдельную модель")
    reopened.window?.orderOut(nil)
    var missingSettings = saved
    missingSettings.apiRecognitionModel = .whisper("/missing/ggml-removed-model.bin")
    SettingsStore.save(missingSettings)
    let missingController = SettingsWindow()
    missingController.show(); missingController.selectTab("api")
    let missingModel = descendants(missingController.window!.contentView!).compactMap { $0 as? NSPopUpButton }
        .first { $0.identifier?.rawValue == "api-recognition-model" }!
    expect(missingModel.titleOfSelectedItem?.hasPrefix("Недоступна:") == true && missingModel.selectedItem?.isEnabled == false,
           "Удалённая модель API остаётся видимой и недоступной без подмены выбора")
    missingController.window?.orderOut(nil)
    SettingsStore.save(saved)
}

// Вложенный RunLoop должен обслуживать IPC, поэтому стартуем из timer,
// а не удерживаем выполняющийся блок serial main queue.
let startTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
    do {
        try testPauseHUD()
        if CommandLine.arguments.contains("--hud-only") {
            print("OK: \(checks) проверок HUD без тестов настроек и распознавания")
        } else {
            try runChecks()
            print("OK: \(checks) проверок последовательного выбора моделей, загрузки и сохранения")
        }
        application.terminate(nil)
    } catch {
        FileHandle.standardError.write(Data("Recognition tests: \(error)\n".utf8))
        exit(1)
    }
}
application.run()
