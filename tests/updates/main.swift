import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
var checks = 0
func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    checks += 1; precondition(value(),message)
}
final class Backend: UpdateBackend {
    var sessionInProgress = false
    var onFound: ((String) -> Void)?
    var onFinished: ((Bool, Bool) -> Void)?
    var calls: [Bool] = []
    func start() throws {}
    func check(manual: Bool) { calls.append(manual); sessionInProgress = true }
    func finish(success: Bool = true, version: String? = nil) {
        if let version { onFound?(version) }
        sessionInProgress = false; onFinished?(success,version != nil)
    }
}
var schedule = UpdateSchedule()
let now = Date(timeIntervalSince1970: 1000)
schedule.completed(at: now,success:true)
expect(schedule.nextCheck.timeIntervalSince(now)==86400,"После успеха сутки")
schedule.completed(at: now,success:false)
expect(schedule.nextCheck.timeIntervalSince(now)==3600,"После ошибки час")
let suite = "RunvoiceUpdateTests."+UUID().uuidString
let store = UserDefaults(suiteName:suite)!
defer { store.removePersistentDomain(forName:suite) }
store.set("1.1.10",forKey:"RunvoiceAvailableUpdate")
let coordinator = UpdateCoordinator(defaults:store,version:"1.1.9")
expect(coordinator.availableVersion=="1.1.10","Версии сравниваются численно, кэш восстанавливается")
expect(UpdateCoordinator(defaults:store,version:"1.1.10").availableVersion==nil,"Обновлённое приложение не показывает старую точку")
let backend=Backend();coordinator.start(backend:backend)
expect(backend.calls == [false],"Тихая проверка при запуске")
coordinator.check();coordinator.tick()
expect(backend.calls.count==1,"Параллельные проверки исключены")
backend.finish(success:false)
expect(coordinator.availableVersion=="1.1.10","Ошибка не сбрасывает найденное обновление")
coordinator.tick(now:Date().addingTimeInterval(3500))
expect(backend.calls.count==1,"Нет преждевременного повтора")
coordinator.tick(now:Date().addingTimeInterval(3700))
expect(backend.calls.count==2 && backend.calls.last==false,"Автоматический повтор после часа")
backend.finish(version:"1.1.11")
expect(coordinator.availableVersion=="1.1.11","Новая версия обновляет индикатор")
coordinator.check()
expect(backend.calls.last==true,"Кнопка инициирует ручную проверку")
backend.finish()
expect(coordinator.availableVersion==nil,"Актуальная версия убирает индикатор")
var busy=true,installed=0,cancelled=0,barriers=0
coordinator.isBusy={busy};coordinator.beforeInstall={barriers += 1}
coordinator.requestInstallation(install:{installed += 1},cancel:{cancelled += 1})
expect(installed==0 && !coordinator.isInstalling,"Занятость откладывает установку без прерывания работ")
coordinator.tick();expect(installed==0,"Пауза диктовки и другие признаки занятости продолжают ожидание")
coordinator.cancelWaiting()
expect(cancelled==1 && installed==0,"Отмена ожидания не устанавливает обновление")
coordinator.requestInstallation(install:{installed += 1},cancel:{cancelled += 1})
busy=false;coordinator.tick()
expect(installed==1 && barriers==1 && coordinator.isInstalling,"Установка начинается после повторной проверки занятости")
let count=backend.calls.count;coordinator.check()
expect(backend.calls.count==count,"Во время замены приложения новые проверки запрещены")
let badge=UpdateBadgeView(frame:NSRect(x:0,y:0,width:7,height:7))
expect(badge.hitTest(.zero)==nil,"Точка не перехватывает клики меню")
print("OK: \(checks) проверок обновлений, расписания, кэша и ожидания установки")
