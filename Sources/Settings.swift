import Foundation
import Security

extension Notification.Name {
    static let credentialsChanged = Notification.Name("mailcloud.credentialsChanged")
}

enum Keychain {
    private static let service = "ru.local.MailCloudSync"

    static func set(_ value: String?, key: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        guard let value = value, !value.isEmpty else { return }
        var q = base
        q[kSecValueData as String] = value.data(using: .utf8)!
        SecItemAdd(q as CFDictionary, nil)
    }

    static func get(key: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

final class Settings {
    static let shared = Settings()
    static let defaultServer = "https://webdav.cloud.mail.ru"
    private let d = UserDefaults.standard
    private var passwordLoaded = false
    private var passwordValue: String?

    /// Пароль внешнего приложения хранится в связке ключей.
    var password: String? {
        get {
            if !passwordLoaded { passwordValue = Keychain.get(key: "password"); passwordLoaded = true }
            return passwordValue
        }
        set {
            passwordValue = newValue
            passwordLoaded = true
            Keychain.set(newValue, key: "password")
        }
    }

    var email: String {
        get { d.string(forKey: "email") ?? "" }
        set { d.set(newValue, forKey: "email") }
    }
    var serverURL: String {
        get { let v = d.string(forKey: "serverURL") ?? ""; return v.isEmpty ? Settings.defaultServer : v }
        set { d.set(newValue, forKey: "serverURL") }
    }
    var localFolder: String {
        get { d.string(forKey: "localFolder") ?? "" }
        set { d.set(newValue, forKey: "localFolder") }
    }
    /// Папки Облака, которые синхронизируются: ["/"] — всё, иначе например ["/Документы", "/Фото/2024"].
    var selectedFolders: [String] {
        get { Settings.normalize(d.stringArray(forKey: "selectedFolders") ?? []) }
        set { d.set(Settings.normalize(newValue), forKey: "selectedFolders") }
    }
    /// Исключения: папки внутри выбранной, которые синхронизировать не нужно.
    var excludedFolders: [String] {
        get { Settings.normalize(d.stringArray(forKey: "excludedFolders") ?? []) }
        set { d.set(Settings.normalize(newValue), forKey: "excludedFolders") }
    }
    /// Пользователь хотя бы раз явно выбрал, что синхронизировать.
    var selectionConfirmed: Bool {
        get { d.bool(forKey: "selectionConfirmed") }
        set { d.set(newValue, forKey: "selectionConfirmed") }
    }
    var intervalMinutes: Int {
        get { let v = d.integer(forKey: "intervalMinutes"); return v > 0 ? v : 5 }
        set { d.set(newValue, forKey: "intervalMinutes") }
    }
    var paused: Bool {
        get { d.bool(forKey: "paused") }
        set { d.set(newValue, forKey: "paused") }
    }

    /// Приводит пути к виду "/A/B", убирает дубли (вложенность разбирает окно выбора).
    static func normalize(_ list: [String]) -> [String] {
        var items: [String] = []
        for var p in list {
            p = p.trimmingCharacters(in: .whitespacesAndNewlines)
            if !p.hasPrefix("/") { p = "/" + p }
            while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
            items.append(p.precomposedStringWithCanonicalMapping)
        }
        return Array(Set(items)).sorted()
    }

    var isConnected: Bool { !email.isEmpty && password != nil }

    var isConfigured: Bool {
        isConnected && !localFolder.isEmpty && selectionConfirmed && !selectedFolders.isEmpty
    }

    func makeClient() -> WebDAVClient? {
        guard let pw = password, !email.isEmpty else { return nil }
        return WebDAVClient(server: serverURL, email: email, password: pw)
    }
}
