import AppKit

/// AppKit маршрутизирует стандартные сочетания через mainMenu и responder chain.
/// Меню строки состояния само по себе этого не обеспечивает.
enum TextEditingCommands {
    static func install(in application: NSApplication) {
        application.mainMenu = makeMenu()
    }

    static func makeMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem(title: "Runvoice", action: nil, keyEquivalent: "")
        let application = NSMenu(title: "Runvoice")
        application.addItem(withTitle: "Завершить Runvoice", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = application
        main.addItem(appItem)
        let editItem = NSMenuItem(title: "Правка", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Правка")
        edit.addItem(withTitle: "Отменить", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Повторить", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Копировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Выделить всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }

}
