import AppKit

let application = NSApplication.shared
application.setActivationPolicy(.regular)
let destination = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/updater/e2e")
let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as! String
if version == "2.0" {
    try! Data("installed".utf8).write(to: destination.appendingPathComponent("installed-marker"))
    exit(0)
}
var began: Date?
var manual = false
var clicked = Set<String>()
func descendants(_ view: NSView) -> [NSView] { [view]+view.subviews.flatMap(descendants) }
UpdateCoordinator.shared.isBusy = {
    if began == nil { began = Date(); try? Data("waiting".utf8).write(to: destination.appendingPathComponent("waiting-marker")) }
    return Date().timeIntervalSince(began!) < 3
}
let backend = SparkleUpdateBackend()
UpdateCoordinator.shared.start(backend:backend)
let timer = Timer.scheduledTimer(withTimeInterval:0.2,repeats:true) { _ in
    UpdateCoordinator.shared.tick()
    if UpdateCoordinator.shared.availableVersion != nil && !backend.sessionInProgress && !manual {
        manual = true; UpdateCoordinator.shared.check()
    }
    for window in application.windows {
        guard let view=window.contentView else {continue}
        for button in descendants(view).compactMap({$0 as? NSButton}) where button.isEnabled && !button.isHidden {
            let title=button.title.lowercased()
            if (title == "install update" || title == "install and relaunch" || title == "установить обновление" || title == "установить и перезапустить") && !clicked.contains(title) {
                clicked.insert(title)
                print("click \(button.title)")
                button.performClick(nil)
            }
        }
    }

}
RunLoop.main.add(timer,forMode:.common)
application.run()
