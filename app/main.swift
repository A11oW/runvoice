import AppKit

// MARK: - Точка входа

let app = NSApplication.shared
TextEditingCommands.install(in: app)
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
