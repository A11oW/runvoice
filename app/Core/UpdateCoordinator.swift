import AppKit

protocol UpdateBackend: AnyObject {
    var sessionInProgress: Bool { get }
    var onFound: ((String) -> Void)? { get set }
    var onFinished: ((Bool, Bool) -> Void)? { get set }
    func start() throws
    func check(manual: Bool)
    func focus()
}
extension UpdateBackend { func focus() {} }

struct UpdateSchedule {
    var nextCheck = Date.distantPast
    mutating func completed(at now: Date, success: Bool) {
        nextCheck = now.addingTimeInterval(success ? 86400 : 3600)
    }
}

/// Не изменяет настройки диктовки. Таймер и все переходы — на main.
final class UpdateCoordinator {
    static let shared = UpdateCoordinator()
    static let didChange = Notification.Name("RunvoiceUpdateChanged")
    private let defaults: UserDefaults
    private let installedVersion: String
    private var backend: UpdateBackend?
    private var timer: Timer?
    private var schedule = UpdateSchedule()
    private var pendingInstall: (() -> Void)?
    private var pendingCancel: (() -> Void)?
    private var waitPanel: NSPanel?
    private(set) var isInstalling = false
    private(set) var availableVersion: String?
    private(set) var status = "Проверка при запуске и раз в сутки"
    var isBusy: () -> Bool = { false }
    var beforeInstall: () -> Void = {}
    init(defaults: UserDefaults = .standard, version: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") {
        self.defaults = defaults; self.installedVersion = version
        if let saved = defaults.string(forKey: "RunvoiceAvailableUpdate"), saved.compare(version, options: .numeric) == .orderedDescending { availableVersion = saved }
    }
    func start(backend: UpdateBackend) {
        guard self.backend == nil else { return }
        self.backend = backend
        backend.onFound = { [weak self] version in
            guard let self else { return }
            self.availableVersion = version; self.defaults.set(version, forKey: "RunvoiceAvailableUpdate")
            self.status = "Доступна версия \(version)"; self.changed()
        }
        backend.onFinished = { [weak self] success, found in
            guard let self else { return }
            self.schedule.completed(at: Date(), success: success)
            if success && !found { self.availableVersion = nil; self.defaults.removeObject(forKey: "RunvoiceAvailableUpdate") }
            self.status = success ? (self.availableVersion.map { "Доступна версия \($0)" } ?? "Установлена актуальная версия") : "Не удалось проверить обновления. Повтор через час."
            if !success && self.isInstalling { self.isInstalling = false }
            self.changed()
        }
        do { try backend.start() } catch { self.backend = nil; status = "Не удалось запустить проверку обновлений"; changed(); return }
        check(manual: false)
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.tick() }
    }
    func tick(now: Date = Date()) {
        if pendingInstall != nil { if !isBusy() { finishWaiting() }; return }
        if now >= schedule.nextCheck { check(manual: false) }
    }
    func check(manual: Bool = true) {
        guard let backend, !isInstalling, pendingInstall == nil else { return }
        if backend.sessionInProgress { if manual { backend.focus() }; return }
        status = "Проверяю обновления…"; changed(); backend.check(manual: manual)
    }
    func requestInstallation(install: @escaping () -> Void, cancel: @escaping () -> Void) {
        guard !isInstalling else { return }
        pendingInstall = install; pendingCancel = cancel
        if !isBusy() { finishWaiting(); return }
        status = "Установка ожидает завершения текущих операций"; changed()
        let panel = NSPanel(contentRect: NSRect(x: 0,y: 0,width: 440,height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Обновление Runvoice"
        let text = NSTextField(wrappingLabelWithString: "Дождитесь завершения диктовки, записи, загрузки моделей и API-запросов. Диктовка на паузе тоже считается занятой.")
        text.frame = NSRect(x: 20,y: 50,width: 400,height: 55)
        let button = NSButton(title: "Отменить ожидание", target: self, action: #selector(cancelWaiting))
        button.frame = NSRect(x: 235,y: 12,width: 185,height: 28)
        panel.contentView?.addSubview(text); panel.contentView?.addSubview(button)
        waitPanel = panel; panel.center(); panel.makeKeyAndOrderFront(nil)
    }
    private func finishWaiting() {
        guard !isBusy(), let install = pendingInstall else { return }
        pendingInstall = nil; pendingCancel = nil; waitPanel?.orderOut(nil); waitPanel = nil
        isInstalling = true; beforeInstall(); changed(); install()
    }
    @objc func cancelWaiting() {
        let cancel = pendingCancel; pendingInstall = nil; pendingCancel = nil
        waitPanel?.orderOut(nil); waitPanel = nil
        status = availableVersion.map { "Доступна версия \($0)" } ?? "Установка отложена"
        cancel?(); changed()
    }
    private func changed() { NotificationCenter.default.post(name: Self.didChange, object: self) }
    deinit { timer?.invalidate() }
}
