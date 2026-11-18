import SwiftUI
import Cocoa
import ServiceManagement

// MARK: - Дерево папок Облака

final class FolderNode: ObservableObject, Identifiable {
    let name: String
    let path: String
    @Published var children: [FolderNode]? = nil
    @Published var expanded = false
    @Published var loading = false
    @Published var error: String? = nil
    var id: String { path }

    init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

final class FolderTreeModel: ObservableObject {
    let root = FolderNode(name: "Облако", path: "/")
    /// Отмеченные пути. "/" — корень, то есть всё Облако.
    @Published var selected: Set<String>

    init() {
        selected = Settings.shared.selectionConfirmed ? Set(Settings.shared.selectedFolders) : []
    }

    var result: [String] { Settings.normalize(Array(selected)) }

    var summary: String {
        if selected.contains("/") { return "Всё Облако" }
        if selected.isEmpty { return "Ничего не выбрано" }
        let names = selected.sorted().map { ($0 as NSString).lastPathComponent }
        let shown = names.prefix(3).joined(separator: ", ")
        return names.count > 3 ? "\(shown) и ещё \(names.count - 3)" : shown
    }

    /// Выбрана ли уже сама папка или её родитель (тогда вложенные включены автоматически).
    func isCovered(_ path: String) -> Bool {
        selected.contains("/") || selected.contains { path.hasPrefix($0 + "/") }
    }

    func toggle(_ path: String, on: Bool) {
        if path == "/" {
            selected = on ? ["/"] : []
            return
        }
        if on {
            selected = selected.filter { !$0.hasPrefix(path + "/") }
            selected.insert(path)
        } else {
            selected.remove(path)
        }
    }

    func load(_ node: FolderNode) {
        guard let api = Settings.shared.makeClient(), node.children == nil, !node.loading else { return }
        node.loading = true
        node.error = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let names = try api.listDirs(node.path)
                DispatchQueue.main.async {
                    let base = node.path == "/" ? "" : node.path
                    node.children = names.map { FolderNode(name: $0, path: base + "/" + $0) }
                    node.loading = false
                }
            } catch {
                DispatchQueue.main.async {
                    node.error = error.localizedDescription
                    node.children = []
                    node.loading = false
                }
            }
        }
    }

    func reload() {
        root.children = nil
        load(root)
    }
}

struct FolderList: View {
    @ObservedObject var node: FolderNode
    @ObservedObject var model: FolderTreeModel
    let level: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let err = node.error {
                Text(err).font(.caption).foregroundColor(.red)
                    .padding(.leading, CGFloat(level) * 18)
            }
            if let ch = node.children {
                if ch.isEmpty && node.error == nil {
                    Text("Вложенных папок нет").font(.caption).foregroundColor(.secondary)
                        .padding(.leading, CGFloat(level) * 18 + 18)
                }
                ForEach(ch) { FolderRow(node: $0, model: model, level: level) }
            } else if node.loading {
                Text("Загрузка списка папок…").font(.caption).foregroundColor(.secondary)
                    .padding(.leading, CGFloat(level) * 18 + 18)
            }
        }
    }
}

struct FolderRow: View {
    @ObservedObject var node: FolderNode
    @ObservedObject var model: FolderTreeModel
    let level: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Button(action: {
                    node.expanded.toggle()
                    if node.expanded { model.load(node) }
                }) {
                    Image(systemName: node.expanded ? "chevron.down" : "chevron.right").frame(width: 14)
                }
                .buttonStyle(PlainButtonStyle())
                Toggle(isOn: Binding(
                    get: { model.selected.contains(node.path) || model.isCovered(node.path) },
                    set: { model.toggle(node.path, on: $0) })) {
                    Label(node.name, systemImage: "folder")
                }
                .disabled(model.isCovered(node.path))
            }
            .padding(.leading, CGFloat(level) * 18)
            if node.expanded {
                FolderList(node: node, model: model, level: level + 1)
            }
        }
    }
}

// MARK: - Окно выбора папок

struct FolderPickerView: View {
    @ObservedObject var model: FolderTreeModel
    var onDone: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Что синхронизировать").font(.headline)
            Text("Отметьте корень «Всё Облако», чтобы синхронизировать всё, или выберите отдельные папки. "
                 + "Если снять галочку с папки, её копия на Маке удалится (в Корзину), а в Облаке ничего не изменится.")
                .font(.caption).foregroundColor(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: Binding(
                        get: { model.selected.contains("/") },
                        set: { model.toggle("/", on: $0) })) {
                        Label("Всё Облако (корень)", systemImage: "externaldrive")
                    }
                    FolderList(node: model.root, model: model, level: 1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .border(Color.gray.opacity(0.4))
            HStack {
                Text("Выбрано: " + model.summary).font(.caption)
                Spacer()
                Button("Обновить список") { model.reload() }
                Button("Отмена") { onCancel() }
                Button("Готово") { onDone() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(minWidth: 460, minHeight: 440)
    }
}

final class PickerWindowController {
    static let shared = PickerWindowController()
    private var window: NSWindow?

    func show(model: FolderTreeModel) {
        window?.close()
        let snapshot = model.selected
        let view = FolderPickerView(
            model: model,
            onDone: { [weak self] in self?.window?.close() },
            onCancel: { [weak self] in model.selected = snapshot; self?.window?.close() })
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 560),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Что синхронизировать"
        w.contentView = NSHostingView(rootView: view)
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        model.load(model.root)
    }
}

// MARK: - Окно настроек

struct SettingsView: View {
    @State private var email = Settings.shared.email
    @State private var password = ""
    @State private var serverURL = Settings.shared.serverURL
    @State private var connecting = false
    @State private var localFolder = Settings.shared.localFolder
    @State private var interval = Settings.shared.intervalMinutes
    @State private var loggedIn = Settings.shared.isConnected
    @State private var launchAtLogin = false
    @StateObject private var model = FolderTreeModel()

    var onApply: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Аккаунт
            Text("1. Аккаунт").font(.headline)
            HStack {
                Text(loggedIn ? "✅ Подключено: \(Settings.shared.email)" : "Не подключено")
                Spacer()
                if loggedIn {
                    Button("Отключить аккаунт") {
                        Settings.shared.password = nil
                        loggedIn = false
                        model.root.children = nil
                    }
                }
            }
            HStack {
                TextField("Почта Mail.ru, например name@mail.ru", text: $email)
                SecureField("Пароль внешнего приложения", text: $password)
                Button(connecting ? "Проверка…" : "Подключить") { connect() }
                    .disabled(connecting || email.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
            }
            HStack {
                Button("Как создать пароль внешнего приложения") {
                    if let u = URL(string: "https://id.mail.ru/security") { NSWorkspace.shared.open(u) }
                }
                Spacer()
            }
            HStack {
                Text("Адрес WebDAV").font(.caption).foregroundColor(.secondary)
                TextField(Settings.defaultServer, text: $serverURL).font(.caption)
            }

            Divider()

            // Папка на Маке
            Text("2. Папка на этом Маке").font(.headline)
            HStack {
                Text(localFolder.isEmpty ? "Не выбрана" : localFolder)
                    .foregroundColor(localFolder.isEmpty ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Выбрать…") { chooseFolder() }
            }

            Divider()

            // Что синхронизировать
            Text("3. Что синхронизировать").font(.headline)
            HStack {
                Text(loggedIn ? model.summary : "Сначала подключите аккаунт")
                    .foregroundColor(loggedIn ? .primary : .secondary)
                    .lineLimit(1)
                Spacer()
                Button("Выбрать папки Облака…") { PickerWindowController.shared.show(model: model) }
                    .disabled(!loggedIn)
            }

            Divider()

            HStack {
                Text("Проверять Облако раз в")
                Picker("", selection: $interval) {
                    ForEach([1, 5, 15, 30, 60], id: \.self) { Text("\($0) мин").tag($0) }
                }
                .labelsHidden().frame(width: 90)
                Text("(изменения на Маке отправляются сразу)").font(.caption).foregroundColor(.secondary)
                Spacer()
            }
            if #available(macOS 13.0, *) {
                Toggle("Запускать при входе в систему", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { on in
                        if on { try? SMAppService.mainApp.register() }
                        else { try? SMAppService.mainApp.unregister() }
                    }
            }

            HStack {
                Spacer()
                Button("Закрыть") { onClose() }
                Button("Сохранить и синхронизировать") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640)
        .onAppear {
            if #available(macOS 13.0, *) { launchAtLogin = (SMAppService.mainApp.status == .enabled) }
            if loggedIn { model.load(model.root) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .credentialsChanged)) { _ in
            let nowIn = Settings.shared.isConnected
            loggedIn = nowIn
            guard nowIn else { return }
            model.reload()
            // После подключения сразу открываем окно выбора папок
            if !Settings.shared.selectionConfirmed && model.selected.isEmpty {
                PickerWindowController.shared.show(model: model)
            }
        }
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    /// Проверяем логин и пароль на сервере, и только потом сохраняем.
    private func connect() {
        let mail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let pw = password
        let server = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        connecting = true
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            do {
                try WebDAVClient(server: server.isEmpty ? Settings.defaultServer : server,
                                 email: mail, password: pw).checkConnection()
            } catch SyncError.http(let code, _) where code == 403 || code == 405 {
                failure = "Сервер отказал в доступе по WebDAV (код \(code)). Доступ по WebDAV в Облаке Mail.ru входит только в платные тарифы."
            } catch {
                failure = error.localizedDescription
            }
            DispatchQueue.main.async {
                connecting = false
                if let f = failure {
                    alert("Не удалось подключиться", f)
                    return
                }
                Settings.shared.email = mail
                Settings.shared.serverURL = server
                Settings.shared.password = pw
                password = ""
                loggedIn = true
                NotificationCenter.default.post(name: .credentialsChanged, object: nil)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Выбрать"
        panel.message = "Выберите (или создайте) папку, в которую будут скачиваться файлы из Облака"
        if panel.runModal() == .OK, let url = panel.url { localFolder = url.path }
    }

    private func save() {
        let home = NSHomeDirectory()
        if localFolder.isEmpty {
            alert("Выберите папку на Маке", "Укажите папку, в которую будут скачиваться файлы.")
            return
        }
        if localFolder == "/" || localFolder == home {
            alert("Выберите отдельную папку",
                  "Нельзя синхронизировать с корнем диска или всей домашней папкой — создайте для этого свою папку, например «Облако Mail.ru».")
            return
        }
        if !Settings.shared.isConnected {
            alert("Аккаунт не подключён", "Введите почту и пароль внешнего приложения и нажмите «Подключить».")
            return
        }
        if model.selected.isEmpty {
            alert("Выберите, что синхронизировать", "Откройте «Выбрать папки Облака…» и отметьте корень или нужные папки.")
            return
        }
        Settings.shared.localFolder = localFolder
        Settings.shared.selectedFolders = model.result
        Settings.shared.selectionConfirmed = true
        Settings.shared.intervalMinutes = interval
        onApply()
        onClose()
    }
}

final class SettingsWindowController {
    private var window: NSWindow?

    func show(onApply: @escaping () -> Void) {
        window?.close()
        let view = SettingsView(onApply: onApply, onClose: { [weak self] in self?.window?.close() })
        let host = NSHostingView(rootView: view)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 500),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Синхронизация Облака Mail.ru"
        w.contentView = host
        w.setContentSize(host.fittingSize)
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}
