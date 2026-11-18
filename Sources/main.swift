import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let engine = SyncEngine()
    private let tray = StatusController()
    private let settingsWindow = SettingsWindowController()
    private let activityWindow = ActivityWindowController()

    func applicationWillFinishLaunching(_ notification: Notification) {
        installMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine.onStatus = { [weak self] s in
            DispatchQueue.main.async {
                self?.tray.update(s)
                ActivityLog.shared.apply(s)
            }
        }
        tray.onOpenSettings = { [weak self] in self?.openSettings() }
        tray.onOpenActivity = { [weak self] in self?.openActivity() }
        tray.onSyncNow = { [weak self] in self?.engine.requestSync() }
        tray.onConfirmDeletes = { [weak self] in self?.engine.requestSync(allowMassDelete: true) }
        tray.onTogglePause = { [weak self] in
            Settings.shared.paused.toggle()
            self?.engine.reschedule()
        }
        engine.reschedule()
        if !Settings.shared.isConfigured { openSettings() }
    }

    private func openActivity() {
        activityWindow.show { [weak self] in self?.engine.requestSync() }
    }

    private func openSettings() {
        settingsWindow.show { [weak self] in self?.engine.reschedule() }
    }

    /// Без главного меню в полях ввода не работают ⌘V / ⌘C.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Правка")
        edit.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Копировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Выбрать всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
