#if canImport(Sparkle)
import AppKit
import Sparkle

/// Стандартный интерфейс Sparkle с проверкой занятости до выбора Install.
private final class RunvoiceUpdateDriver: SPUStandardUserDriver {
    private func guarded(_ reply: @escaping (SPUUserUpdateChoice) -> Void) -> (SPUUserUpdateChoice) -> Void {
        { choice in
            if choice == .install {
                UpdateCoordinator.shared.requestInstallation(install: { reply(.install) }, cancel: { reply(.dismiss) })
            } else { reply(choice) }
        }
    }
    override func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        super.showReady(toInstallAndRelaunch: guarded(reply))
    }
    override func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        super.showUpdateFound(with: appcastItem, state: state, reply: state.stage == .notDownloaded ? reply : guarded(reply))
    }
}

final class SparkleUpdateBackend: NSObject, UpdateBackend, SPUUpdaterDelegate {
    var onFound: ((String) -> Void)?
    var onFinished: ((Bool, Bool) -> Void)?
    private var found = false
    private lazy var driver = RunvoiceUpdateDriver(hostBundle: .main, delegate: nil)
    private lazy var updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
    var sessionInProgress: Bool { updater.sessionInProgress }
    func start() throws { try updater.start() }
    func focus() { updater.checkForUpdates() }
    func check(manual: Bool) {
        found = false
        if manual { updater.checkForUpdates() } else { updater.checkForUpdateInformation() }
    }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        found = true; onFound?(item.versionString)
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        onFinished?(error == nil || (error as NSError?)?.code == 1001, found)
    }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        // Повторная проверка непосредственно перед завершением приложения.
        if UpdateCoordinator.shared.isInstalling { return false }
        UpdateCoordinator.shared.requestInstallation(install: installHandler, cancel: {})
        return true
    }
}
#endif
