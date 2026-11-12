import Foundation
import CoreGraphics

func testEscapeToCancel() {
    let first = UUID(), second = UUID()
    var policy = DictationKeyPolicy()
    expect(policy.handle(.down, keyCode: 53, finishOnEnter: true, recordingSessionID: first) == .passThrough,
           "Esc выключен независимо от Enter")
    for phase in ["idle", "preparing", "transcribing", "fixing", "improving"] {
        expect(policy.handle(.down, keyCode: 53, finishOnEnter: true, cancelOnEscape: true,
                             recordingSessionID: nil) == .passThrough, "Esc обычный в \(phase)")
    }
    expect(policy.handle(.down, keyCode: 53, modified: true, finishOnEnter: false, cancelOnEscape: true,
                         recordingSessionID: first) == .passThrough, "Модифицированный Esc не отменяет запись")
    expect(policy.handle(.down, keyCode: 53, finishOnEnter: true, cancelOnEscape: true, suspended: true,
                         recordingSessionID: first) == .passThrough, "Назначение хоткея получает Esc")
    expect(policy.handle(.down, keyCode: 53, isRepeat: true, finishOnEnter: true, cancelOnEscape: true,
                         recordingSessionID: first) == .passThrough, "Esc, удерживаемый до записи, не отменяет её")
    expect(policy.handle(.down, keyCode: 53, finishOnEnter: false, cancelOnEscape: true,
                         recordingSessionID: first) == .cancel(first), "Esc отменяет исходную запись, Enter может быть выключен")
    expect(policy.handle(.down, keyCode: 53, isRepeat: true, finishOnEnter: false, cancelOnEscape: false,
                         recordingSessionID: nil) == .consume, "Повторы Esc после отмены поглощены")
    expect(policy.handle(.up, keyCode: 53, finishOnEnter: false, recordingSessionID: nil) == .consume,
           "Отпускание Esc не закрывает окно редактора")
    expect(policy.handle(.down, keyCode: 53, finishOnEnter: true, cancelOnEscape: true,
                         recordingSessionID: nil) == .passThrough, "Следующий Esc вне записи обычный")
    _ = policy.handle(.down, keyCode: 53, finishOnEnter: true, cancelOnEscape: true, recordingSessionID: first)
    expect(policy.handle(.down, keyCode: 53, finishOnEnter: true, cancelOnEscape: true,
                         recordingSessionID: second) == .cancel(second), "Потерянный keyUp не блокирует новую запись")

    let monitor = HotkeyMonitor()
    var settings = Settings()
    settings.cancelRecordingOnEscape = true
    monitor.configure(settings: settings)
    var recording: UUID? = first
    var cancelled: [UUID] = []
    var finished = 0
    monitor.recordingSessionIDProvider = { recording }
    monitor.onCancelRecording = { cancelled.append($0) }
    monitor.onFinishRecording = { _ in finished += 1 }
    func event(_ down: Bool = true, flags: CGEventFlags = [], repeatKey: Bool = false) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: down)!
        event.flags = flags
        event.setIntegerValueField(.keyboardEventAutorepeat, value: repeatKey ? 1 : 0)
        return event
    }
    for flag: CGEventFlags in [.maskControl, .maskShift, .maskCommand, .maskAlternate] {
        expect(!monitor.shouldConsume(event(flags: flag), type: .keyDown), "Модификатор Esc сохранён: \(flag)")
    }
    monitor.setSuspended(true)
    expect(!monitor.shouldConsume(event(), type: .keyDown), "Настройка сочетания получает обычный Esc")
    monitor.setSuspended(false)
    expect(monitor.shouldConsume(event(), type: .keyDown), "Tap поглощает Esc записи")
    recording = second
    spin()
    expect(cancelled == [first] && finished == 0, "Callback Esc сохраняет старый UUID и не вызывает финальный ASR")
    recording = nil
    expect(monitor.shouldConsume(event(repeatKey: true), type: .keyDown), "Tap поглощает удержание Esc после отмены")
    expect(monitor.shouldConsume(event(false), type: .keyUp), "Tap поглощает исходный keyUp Esc")
    expect(!monitor.shouldConsume(event(), type: .keyDown), "Новый Esc вне записи пропускается")
    settings.cancelRecordingOnEscape = false
    monitor.configure(settings: settings)
    recording = second
    expect(!monitor.shouldConsume(event(), type: .keyDown), "Отключение Esc применяется сразу")
}

func testDictationKeyPolicy() {
    let first = UUID(), second = UUID()
    for code: UInt16 in [36, 76] {
        var policy = DictationKeyPolicy()
        expect(policy.handle(.down, keyCode: code, finishOnEnter: false, recordingSessionID: first) == .passThrough,
               "Enter выключен по умолчанию: \(code)")
        for phase in ["idle", "preparing", "transcribing", "fixing", "improving"] {
            expect(policy.handle(.down, keyCode: code, finishOnEnter: true, recordingSessionID: nil) == .passThrough,
                   "Enter работает обычно в \(phase)")
        }
        expect(policy.handle(.down, keyCode: code, modified: true, finishOnEnter: true, recordingSessionID: first) == .passThrough,
               "Модифицированный Enter не завершает запись")
        expect(policy.handle(.down, keyCode: code, finishOnEnter: true, suspended: true, recordingSessionID: first) == .passThrough,
               "Захват сочетания в настройках имеет приоритет")
        expect(policy.handle(.down, keyCode: code, isRepeat: true, finishOnEnter: true, recordingSessionID: first) == .passThrough,
               "Удержание Enter, начатое до записи, не останавливает её")
        expect(policy.handle(.down, keyCode: code, finishOnEnter: true, recordingSessionID: first) == .finish(first),
               "Обычный Enter завершает конкретную запись")
        expect(policy.handle(.down, keyCode: code, isRepeat: true, modified: true, finishOnEnter: false,
                             suspended: true, recordingSessionID: nil) == .consume,
               "Повторы исходного нажатия поглощаются и после остановки/выключения настройки")
        expect(policy.handle(.up, keyCode: code, finishOnEnter: false, suspended: true, recordingSessionID: nil) == .consume,
               "Отпускание исходного нажатия не попадает в чат")
        expect(policy.handle(.down, keyCode: code, finishOnEnter: true, recordingSessionID: nil) == .passThrough,
               "Новое нажатие во время обработки сразу возвращается приложению")
        expect(policy.handle(.up, keyCode: code, finishOnEnter: true, recordingSessionID: nil) == .passThrough,
               "Отпускание нового обычного Enter пропускается")
        expect(policy.handle(.down, keyCode: code, finishOnEnter: true, recordingSessionID: first) == .finish(first),
               "Подготовка проверки потерянного keyUp")
        expect(policy.handle(.down, keyCode: code, finishOnEnter: true, recordingSessionID: nil) == .passThrough,
               "Потерянный keyUp не блокирует следующее физическое нажатие в idle")
        expect(policy.handle(.down, keyCode: code, finishOnEnter: true, recordingSessionID: second) == .finish(second),
               "Новая запись получает собственный идентификатор")
        expect(policy.handle(.up, keyCode: 8, finishOnEnter: true, recordingSessionID: second) == .passThrough,
               "Посторонние клавиши не перехватываются")
    }

    // Синтетические CGEvent подаются непосредственно в настоящий маршрутизатор.
    // Tap не устанавливается; события не публикуются в систему или реальный чат.
    let monitor = HotkeyMonitor()
    var settings = Settings()
    settings.stopRecordingOnEnter = true
    monitor.configure(settings: settings)
    var recording: UUID? = first
    var finished: [UUID] = []
    var toggled = 0
    monitor.recordingSessionIDProvider = { recording }
    monitor.onFinishRecording = { finished.append($0); recording = nil }
    monitor.onAction = { _ in toggled += 1 }

    func event(_ code: CGKeyCode, down: Bool = true, flags: CGEventFlags = [], repeatKey: Bool = false) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
        event.flags = flags
        event.setIntegerValueField(.keyboardEventAutorepeat, value: repeatKey ? 1 : 0)
        return event
    }
    for flags: CGEventFlags in [.maskShift, .maskControl, .maskAlternate, .maskCommand] {
        expect(!monitor.shouldConsume(event(36, flags: flags), type: .keyDown), "Модификатор Enter сохранён: \(flags)")
    }
    expect(!monitor.shouldConsume(event(8, flags: .maskCommand), type: .keyDown), "⌘C не перехватывается")
    monitor.setSuspended(true)
    expect(!monitor.shouldConsume(event(36), type: .keyDown), "Enter пропускается при назначении сочетания")
    monitor.setSuspended(false)
    expect(monitor.shouldConsume(event(36), type: .keyDown), "Return поглощён во время записи")
    expect(finished.isEmpty, "Завершение поставлено в очередь, не выполняется внутри callback tap")
    spin()
    expect(finished == [first] && toggled == 0, "Вызвано завершение, а не toggle/начало новой записи")
    expect(monitor.shouldConsume(event(36, repeatKey: true), type: .keyDown), "Удержание после остановки поглощено")
    expect(monitor.shouldConsume(event(36, down: false), type: .keyUp), "Первый keyUp поглощён")
    let passed = !monitor.shouldConsume(event(36), type: .keyDown)
    expect(passed, "Тестовая форма получила только новое нажатие после остановки")
    expect(!monitor.shouldConsume(event(36, down: false), type: .keyUp), "Новый keyUp также обычный")
    spin()
    expect(finished == [first], "Один Enter запустил одно завершение")

    recording = second
    expect(monitor.shouldConsume(event(76, flags: .maskNumericPad), type: .keyDown), "Enter цифрового блока работает")
    // Сессия сменилась прежде, чем очередь обработала callback: передаём старый
    // токен, чтобы finishRecording мог отклонить его, не завершив новую запись.
    recording = UUID()
    spin()
    expect(finished.last == second, "Отложенный callback сохраняет идентификатор исходной записи")
    _ = monitor.shouldConsume(event(76, down: false), type: .keyUp)
    recording = first
    settings.stopRecordingOnEnter = false
    monitor.configure(settings: settings)
    expect(!monitor.shouldConsume(event(36), type: .keyDown), "Настройка выключается без переустановки приложения")
    expect(monitor.shouldConsume(event(49, flags: .maskAlternate), type: .keyDown), "Основной ⌥Space сохранён")
    expect(!monitor.shouldConsume(event(49, down: false, flags: .maskAlternate), type: .keyUp), "KeyUp основного хоткея не вызывает toggle")
    spin()
    expect(toggled == 1, "Основной хоткей вызван ровно один раз")
}
