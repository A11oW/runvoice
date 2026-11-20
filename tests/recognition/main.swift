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
    HistoryStore.shared.add(text: "Пример записи", raw: nil, model: nil)
    HistoryStore.shared.add(text: "Ещё одна запись", raw: nil, model: nil)
    let isolation = SettingsWindow()
    var commonSaves = 0, apiSaves = 0
    isolation.onSettingsSaved = { commonSaves += 1 }
    isolation.onAPISettingsSaved = { apiSaves += 1 }
    isolation.show(); isolation.selectTab("api")
    let isolationViews = descendants(isolation.window!.contentView!)
    let apiLabels = isolationViews.compactMap { ($0 as? NSTextField)?.stringValue }
    expect(apiLabels.contains("Модель распознавания") && apiLabels.contains("runvoice-active")
           && apiLabels.contains("Использовать для распознавания"), "В API отдельно показаны псевдоним клиента и выбор модели")
    let apiButtons = isolationViews.compactMap { $0 as? NSButton }
    let checkConnection = apiButtons.first { $0.title == "Проверить соединение" }!
    let restartServer = apiButtons.first { $0.title == "Перезапустить сервер" }!
    expect(!checkConnection.isEnabled && !restartServer.isEnabled, "При выключенном API диагностика недоступна")
    let copyAddress = apiButtons.first { $0.accessibilityLabel() == "Копировать адрес API" }!
    let copyAlias = apiButtons.first { $0.accessibilityLabel() == "Копировать модель распознавания API" }!
    let clipboard = NSPasteboard.general
    let previousItems = (clipboard.pasteboardItems ?? []).map { item in
        let copy = NSPasteboardItem()
        for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
        return copy
    }
    copyAddress.performClick(nil)
    let copiedAddress = clipboard.string(forType: .string)
    copyAlias.performClick(nil)
    let copiedAlias = clipboard.string(forType: .string)
    clipboard.clearContents()
    if !previousItems.isEmpty { clipboard.writeObjects(previousItems) }
    expect(copiedAddress == "http://127.0.0.1:8790/runvoice/v1/audio/transcriptions"
           && copiedAlias == "runvoice-active", "Кнопки копируют адрес и псевдоним отдельно")
    let isolationPort = isolationViews.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "api-port" }!
    isolationPort.stringValue = "8799"
    isolation.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: isolationPort))
    expect(!copyAddress.isEnabled && copyAlias.isEnabled, "Неверный порт отключает только копирование адреса")
    isolationPort.stringValue = "8790"
    isolation.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: isolationPort))
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
    func views() -> [NSView] {
        let visible = descendants(root)
        let cells = visible.compactMap { $0 as? NSTableView }.flatMap { table in
            (0..<table.numberOfRows).flatMap { row in
                (0..<table.numberOfColumns).compactMap { table.view(atColumn: $0, row: row, makeIfNecessary: true) }
            }.flatMap(descendants)
        }
        var seen = Set<ObjectIdentifier>()
        return (visible + cells).filter { seen.insert(ObjectIdentifier($0)).inserted }
    }
    func labels() -> [String] { views().compactMap { ($0 as? NSTextField)?.stringValue } }
    func button(_ predicate: (NSButton) -> Bool, line: UInt = #line) -> NSButton {
        let buttons = views().compactMap { $0 as? NSButton }
        guard let match = buttons.first(where: predicate) else {
            preconditionFailure("Кнопка не найдена в сценарии на строке \(line): \(buttons.map(\.title))")
        }
        return match
    }
    controller.selectTab("history")
    let historyList = views().compactMap { $0 as? NSTableView }.first!
    expect(historyList.usesAlternatingRowBackgroundColors && labels().contains("Всего: 2"),
           "История отображает общий счётчик и системное чередование")
    expect(historyList.headerView?.frame.height == 32, "Шапка нативной таблицы имеет высоту 32 pt")
    let search = views().compactMap { $0 as? NSSearchField }.first { $0.placeholderString == "Поиск по тексту" }!
    search.stringValue = "Нет совпадений"
    controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
    expect(historyList.numberOfRows == 0 && labels().contains("Всего: 2") && button { $0.title == "Очистить историю…" }.isEnabled,
           "Фильтр истории не меняет общий итог и не блокирует очистку")
    controller.selectTab("general")
    expect(views().contains { $0.identifier?.rawValue == "check-updates" }, "В Основных доступна ручная проверка обновлений")
    expect(labels().contains { $0.contains("Проверка при запуске и раз в сутки") }, "Основные показывают состояние механизма обновлений без сетевого запуска в тестах")
    expect(!views().contains { $0.identifier?.rawValue == "record-audio-sample" }, "В разделе Основные нет записи сэмпла")
    let sidebarSearch = views().compactMap { $0 as? NSSearchField }.first!
    expect(sidebarSearch.frame.height == 32, "Боковой поиск имеет высоту 32 pt")
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
    expect(!labels().contains(FluidModel.parakeet.title), "В каталоге Whisper нет моделей FluidAudio")
    expect(labels().contains { $0.contains("экспериментальная") }, "Донастройки Whisper явно помечены как экспериментальные")
    let headings = ["Движок", "Найдены на компьютере", "Скачивание"]
    func expectSectionOrder() {
        expect(labels().filter { headings.contains($0) } == headings,
               "Обе технологии показывают движок и две таблицы в одинаковом порядке")
    }
    expectSectionOrder()
    expect(labels().contains("Скачивание"),
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
    func fluidChoice(_ model: FluidModel) -> NSButton {
        button { $0.identifier?.rawValue == model.rawValue && $0.title.isEmpty }
    }
    for model in FluidModel.allCases {
        expect(labels().contains(model.title), "Все модели FluidAudio показаны в совместимом каталоге")
    }
    expect(fluidChoice(.nemotron).state == .on, "Переключение технологии восстанавливает выбранный Nemotron")
    expect(!views().contains { ($0 as? NSButton)?.accessibilityLabel() == "Использовать " + FluidModel.parakeet.title },
           "Нескачанную модель нельзя выбрать до успешной проверки")
    expect(!labels().contains { $0.contains("Whisper") && $0.contains("Turbo") }, "Модели разных технологий не смешиваются")
    expect(!views().contains { ($0 as? NSButton)?.title.contains("резервный Whisper") == true },
           "У FluidAudio нет окна резерва")
    expect(labels().contains { $0.contains("Язык распознавания") }, "Общие параметры доступны для FluidAudio")
    let marker = FluidModelStore.directory(for: .nemotron).appendingPathComponent("installed-model")
    try FileManager.default.removeItem(at: marker)
    button { $0.title == "Сохранить" }.performClick(nil)
    expect(SettingsStore.load().recognitionTechnology == .whisper, "Новая технология без готовой модели не сохраняется")
    expect(labels().contains { $0.contains("Сначала скачайте и проверьте") }, "Недоступная модель объясняется в окне без блокирующего диалога")
    try install(.nemotron)
    selectTechnology(1)
    fluidChoice(.nemotron).performClick(nil)

    let first = WhisperModelStore.modelsDirectory.appendingPathComponent("ggml-tiny.bin")
    let secondModel = WhisperModelCatalog.models.first { $0.experimental }!
    let second = WhisperModelStore.modelsDirectory.appendingPathComponent(secondModel.fileName)
    let fakeModel = Data("lmgg".utf8) + Data(count: 1_000_001)
    try fakeModel.write(to: first)
    try fakeModel.write(to: second)
    selectTechnology(0)
    expect(labels().contains { $0.contains("Язык — подсказка модели") }, "Возврат к Whisper восстанавливает его пояснение")
    button { $0.identifier?.rawValue == second.path && $0.title.isEmpty }.performClick(nil)
    expect(labels().contains { $0.contains("экспериментальная") },
           "У установленного экспериментального Whisper сохраняется пометка")
    expect(!labels().contains("Папки и скрытые модели"), "Отдельного списка папок и скрытых моделей нет")
    selectTechnology(1)
    expect(fluidChoice(.nemotron).state == .on, "Выбор модели сохраняется при смене технологии")
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
    button { $0.identifier?.rawValue == FluidModel.nemotron.rawValue && $0.title == "Проверить" }.performClick(nil)
    waitFor("Прогресс проверки виден в строке установленной модели") {
        labels().contains { $0.contains("Проверка: 50%") }
    }
    expect(!button { $0.identifier?.rawValue == FluidModel.nemotron.rawValue && $0.title == "Удалить модель…" }.isEnabled,
           "Проверяемую модель нельзя удалить")
    button { $0.title == "Отменить проверку" }.performClick(nil)
    expect(FluidModelStore.installed(.nemotron), "Отмена проверки сохраняет установленную модель")
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
    expect(fluidChoice(.nemotron).state == .on, "Скачивание другой модели не меняет выбор")
    expect(fluidChoice(.parakeet).isEnabled, "После успешной загрузки выбор модели становится доступен")
    vocabulary.input.string = "Vitest"
    for model in FluidModel.allCases {
        try install(model)
        selectTechnology(1)
        fluidChoice(model).performClick(nil)
        expectSectionOrder()
        expect(labels().contains { model == .nemotron ? $0.contains("подсказку потоковой модели")
            : $0.contains("ограничивает алфавит") && $0.contains("English — латиница")
                && $0.contains("снять это ограничение") }, "Пояснение языка соответствует выбранной модели \(model.rawValue)")
        expect(language.indexOfSelectedItem == 0 && preview.options == RecognitionPreview(enabled: false, lineCount: 7),
               "Рекомендация Авто не меняет выбранный Русский или параметры предпросмотра")
        expect(vocabulary.input.string == "Vitest", "Смена модели не очищает черновик словаря")
    }
    language.selectItem(at: 2)
    fluidChoice(.parakeet).performClick(nil)
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
    expect(saved.whisperModelPath == second.path, "Технологии сохраняют независимые выбранные модели, включая явный экспериментальный Whisper")
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

    let external = Paths.support.appendingPathComponent("ggml-external.bin")
    let unlinkOnly = Paths.support.appendingPathComponent("ggml-keep-file.bin")
    try fakeModel.write(to: external)
    try fakeModel.write(to: unlinkOnly)
    var removalSettings = saved
    removalSettings.whisperExternalModelPaths = [external.path, unlinkOnly.path]
    var removableProvider = AIProvider.openCodeDefault()
    removableProvider.name = "Черновики"
    let protectedProvider = AIProvider.openCodeDefault()
    removalSettings.providers = [removableProvider, protectedProvider]
    removalSettings.dictationProviderID = protectedProvider.id
    SettingsStore.save(removalSettings)
    controller.show(); controller.selectTab("models"); selectTechnology(0)

    func chooseModalButtons(_ trigger: NSButton, _ choices: [String]) {
        var pending = choices
        let deadline = Date().addingTimeInterval(4)
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            guard let alert = application.modalWindow?.contentView else { return }
            if let title = pending.first,
               let control = descendants(alert).compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) {
                pending.removeFirst()
                control.performClick(nil)
            } else if Date() > deadline {
                application.abortModal()
            }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        trigger.performClick(nil)
        timer.invalidate()
        expect(pending.isEmpty, "В диалогах удаления доступны ожидаемые действия: \(choices)")
    }

    func removeModel(_ file: URL, via choices: [String]) {
        chooseModalButtons(button { $0.identifier?.rawValue == file.path && $0.title == "Удалить модель…" }, choices)
    }

    removeModel(first, via: ["Отмена"])
    expect(FileManager.default.fileExists(atPath: first.path), "Отмена удаления управляемой модели сохраняет файл")
    removeModel(external, via: ["Удалить с диска…", "Отмена"])
    expect(FileManager.default.fileExists(atPath: external.path), "Внешняя модель сохраняется без второго подтверждения")
    removeModel(external, via: ["Удалить с диска…", "Удалить с диска"])
    expect(!FileManager.default.fileExists(atPath: external.path), "Подтверждение удаляет только внешний файл")
    removeModel(unlinkOnly, via: ["Удалить из приложения"])
    expect(FileManager.default.fileExists(atPath: unlinkOnly.path) && !labels().contains("ggml-keep-file.bin"),
           "Удаление из приложения скрывает строку и сохраняет внешний файл")
    controller.selectTab("providers")
    let providerTable = views().compactMap { $0 as? NSTableView }.first!
    expect(providerTable.tableColumns.map(\.title) == ["", "Профиль", "Тип", "Модель", ""],
           "В провайдерах только три колонки данных, отметки и действия")
    expect(!button { $0.accessibilityLabel() == "Выбрать провайдера DeepSeek" }.isEnabled,
           "Используемый профиль защищён от удаления")
    button { $0.accessibilityLabel() == "Выбрать провайдера Черновики" }.performClick(nil)
    expect(labels().contains("Выбрано: 1. Всего: 2"), "У провайдеров единый счётчик отмеченных строк")

    let fm = FileManager.default
    let partial = WhisperModelStore.modelsDirectory.appendingPathComponent("ggml-tiny.bin.download")
    let temporaryAudio = Paths.state.appendingPathComponent("capture-\(UUID().uuidString).wav")
    let modelLink = WhisperModelStore.modelsDirectory.appendingPathComponent("ggml-linked.bin")
    let vadFile = WhisperModelStore.modelsDirectory.appendingPathComponent("ggml-silero-vad.bin")
    let unfinishedFluid = FluidModelStore.directory(for: .phonon25)
    try Data(count: 1700).write(to: partial)
    try Data(count: 2300).write(to: temporaryAudio)
    try fm.createSymbolicLink(at: modelLink, withDestinationURL: unlinkOnly)
    try fakeModel.write(to: vadFile)
    try fm.removeItem(at: unfinishedFluid.appendingPathComponent("installed-model"))
    let usage = SettingsStorage.measure()
    expect((usage.cache ?? 0) >= 4000 && (usage.models ?? 0) >= Int64(fakeModel.count * 2) && (usage.history ?? 0) > 0,
           "Память считает временные файлы, управляемые модели и историю")
    let unreadable = FluidModelStore.directory(for: .nemotron).appendingPathComponent("unreadable", isDirectory: true)
    try fm.createDirectory(at: unreadable, withIntermediateDirectories: false)
    try Data(count: 100).write(to: unreadable.appendingPathComponent("weights"))
    try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
    defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unreadable.path) }
    let partialUsage = SettingsStorage.measure()
    expect(partialUsage.models == nil && partialUsage.total == nil && partialUsage.cache == usage.cache,
           "Недоступный каталог модели влияет только на подсчёт размера моделей и итога")
    let settingsBeforeClear = SettingsStore.load()
    controller.selectTab("general")
    let cacheButton = button { $0.title == "Очистить кеш" }
    let dataButton = button { $0.title == "Очистить данные…" }
    waitFor("Очистка кеша доступна при неполном подсчёте моделей") { cacheButton.isEnabled }
    cacheButton.performClick(nil)
    expect(!fm.fileExists(atPath: partial.path) && !fm.fileExists(atPath: temporaryAudio.path)
           && fm.fileExists(atPath: first.path) && fm.fileExists(atPath: Paths.history.path),
           "Очистка кеша убирает временные файлы, сохраняя модели и историю")
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unreadable.path)
    waitFor("Очистка данных доступна после пересчёта") { dataButton.isEnabled }
    chooseModalButtons(dataButton, ["Отмена"])
    expect(fm.fileExists(atPath: first.path) && fm.fileExists(atPath: Paths.history.path), "Отмена общей очистки сохраняет файлы")
    var modelChanges = 0
    controller.onModelRemoved = { modelChanges += 1 }
    chooseModalButtons(dataButton, ["Очистить данные"])
    let cleared = SettingsStorage.measure()
    expect(cleared.models == 0 && cleared.history == 0 && !fm.fileExists(atPath: first.path)
           && !FluidModelStore.installed(.nemotron) && modelChanges == 1, "Очистка данных удаляет загрузки и историю, обновляет движки")
    expect(SettingsStore.load() == settingsBeforeClear && fm.fileExists(atPath: unlinkOnly.path)
           && fm.fileExists(atPath: modelLink.path) && fm.fileExists(atPath: vadFile.path)
           && fm.fileExists(atPath: unfinishedFluid.path),
           "Настройки, внешний файл, ссылка, VAD и каталог без валидной установки остаются на месте")

    HistoryStore.shared.add(text: "Запись только в памяти", raw: nil, model: nil)
    try fm.removeItem(at: Paths.history)
    expect(!HistoryStore.shared.entries.isEmpty, "После внешнего удаления файла записи ещё загружены")
    waitFor("Общая очистка доступна для загруженной истории") { dataButton.isEnabled }
    chooseModalButtons(dataButton, ["Очистить данные"])
    HistoryStore.shared.add(text: "Новая запись", raw: nil, model: nil)
    expect(HistoryStore.shared.entries.map(\.text) == ["Новая запись"],
           "После общей очистки отсутствующая на диске история не восстанавливается из памяти")
    controller.window?.orderOut(nil)
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
