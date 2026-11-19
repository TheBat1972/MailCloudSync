import Foundation
import Cocoa

/// «Открыть в Облаке Mail.ru» — пункт в контекстном меню Finder («Службы»).
/// Открывает в браузере страницу cloud.mail.ru с этим файлом (для папки — саму папку),
/// где можно нажать «Поделиться» и получить ссылку. Создавать ссылку программа не может:
/// WebDAV этого не умеет.
enum CloudOpener {
    /// «/Users/me/Облако/Документы/a.pdf» → «Документы/a.pdf»
    static func relativePath(forLocal path: String) throws -> String {
        let root = URL(fileURLWithPath: Settings.shared.localFolder).resolvingSymlinksInPath().path
        let p = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard !root.isEmpty, p.hasPrefix(root + "/") else {
            throw SyncError.bad("Файл вне папки синхронизации: " + (path as NSString).lastPathComponent)
        }
        return String(p.dropFirst(root.count + 1))
    }

    static func webURL(forLocal path: String) throws -> URL {
        var rel = try relativePath(forLocal: path)
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        // для файла открываем папку, в которой он лежит
        if !isDir.boolValue { rel = (rel as NSString).deletingLastPathComponent }
        let comps = rel.split(separator: "/").map { String($0) }
        let enc = comps.compactMap { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) }
            .joined(separator: "/")
        let s = "https://cloud.mail.ru/home/" + enc + (enc.isEmpty ? "" : "/")
        guard let url = URL(string: s) else { throw SyncError.bad("Не удалось составить адрес") }
        return url
    }

    static func open(_ paths: [String]) {
        guard Settings.shared.isConfigured else {
            alert("Сначала настройте синхронизацию", "Подключите Облако и выберите папку в настройках.")
            return
        }
        var opened = Set<URL>()
        for p in paths {
            do {
                let url = try webURL(forLocal: p)
                if opened.insert(url).inserted { NSWorkspace.shared.open(url) }
            } catch {
                alert("Не удалось открыть", error.localizedDescription)
                return
            }
        }
    }

    /// Выбор файла в папке синхронизации — для пункта меню в строке меню.
    static func chooseAndOpen() {
        guard Settings.shared.isConfigured else {
            alert("Сначала настройте синхронизацию", "Подключите Облако и выберите папку в настройках.")
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: Settings.shared.localFolder)
        panel.prompt = "Открыть в Облаке"
        panel.message = "Выберите файл или папку внутри папки синхронизации"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { open(panel.urls.map { $0.path }) }
    }

    private static func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

final class ServiceProvider: NSObject {
    @objc func openInCloud(_ pboard: NSPasteboard, userData: String,
                           error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let urls = pboard.readObjects(forClasses: [NSURL.self],
                                            options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else {
            error.pointee = "Не выбрано ни одного файла" as NSString
            return
        }
        let paths = urls.map { $0.path }
        DispatchQueue.main.async { CloudOpener.open(paths) }
    }
}

/// Включает пункт «Открыть в Облаке Mail.ru» в контекстном меню Finder («Службы»).
enum ServiceSetup {
    private static let statusKey = "ru.local.MailCloudSync - Открыть в Облаке Mail.ru - openInCloud"

    static func enable() {
        let domain = "pbs" as CFString
        let key = "NSServicesStatus" as CFString
        var dict = (CFPreferencesCopyAppValue(key, domain) as? [String: Any]) ?? [:]
        dict[statusKey] = [
            "enabled_context_menu": true,
            "enabled_services_menu": true,
            "presentation_modes": ["ContextMenu": true, "FinderPreview": true, "ServicesMenu": true]
        ] as [String: Any]
        CFPreferencesSetAppValue(key, dict as CFDictionary, domain)
        CFPreferencesAppSynchronize(domain)
        NSUpdateDynamicServices()
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/System/Library/CoreServices/pbs")
            p.arguments = ["-update"]
            try? p.run()
            p.waitUntilExit()
        }
    }

    /// Один раз при первом запуске.
    static func enableOnFirstLaunch() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "finderServiceEnabledV1") else { return }
        d.set(true, forKey: "finderServiceEnabledV1")
        enable()
    }

    /// Включает службу и показывает пошаговую подсказку, затем открывает настройки.
    static func enableWithGuide() {
        enable()
        let a = NSAlert()
        a.messageText = "Как включить пункт в меню Finder"
        a.informativeText = """
        Программа уже попыталась включить пункт сама. Если в Finder (правый клик по файлу → «Службы») его всё ещё нет, сделайте так:

        1. В открывшемся окне нажмите «Сочетания клавиш…» (кнопка справа внизу).
        2. Слева выберите «Службы».
        3. Прокрутите список вниз до раздела «Файлы и папки».
        4. Поставьте галочку у «Открыть в Облаке Mail.ru».

        После этого пункт появится в правом клике на любом файле.
        """
        a.addButton(withTitle: "Открыть настройки")
        a.addButton(withTitle: "Отмена")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { openKeyboardSettings() }
    }

    static func openKeyboardSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard") {
            NSWorkspace.shared.open(u)
        }
    }
}
