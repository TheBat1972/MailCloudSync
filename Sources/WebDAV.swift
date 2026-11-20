import Foundation

struct RemoteItem: Codable {
    let isDir: Bool
    let size: Int64
    let modified: Date
    let apiPath: String     // путь на сервере, например "/Документы/a.pdf"
}

enum SyncError: LocalizedError {
    case notConfigured
    case unauthorized
    case http(Int, String)
    case network(String)
    case bad(String)
    case needsConfirmation(String)
    case partial(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Не выполнено подключение или не выбрана папка"
        case .unauthorized: return "Неверная почта или пароль внешнего приложения — проверьте в настройках"
        case .http(let c, let m): return "Облако ответило \(c): \(m)"
        case .network(let m): return "Нет связи: \(m)"
        case .bad(let m): return m
        case .needsConfirmation(let m): return m
        case .partial(let m): return m
        }
    }
}

/// Разбор ответа PROPFIND (multistatus).
private final class MultistatusParser: NSObject, XMLParserDelegate {
    struct Entry {
        var href = ""
        var isDir = false
        var size: Int64 = 0
        var modified: Date? = nil
    }
    private(set) var entries: [Entry] = []
    private var cur: Entry?
    private var text = ""

    private static let rfc1123: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()
    private static let iso = ISO8601DateFormatter()

    static func parseDate(_ s: String) -> Date? {
        rfc1123.date(from: s) ?? iso.date(from: s)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        text = ""
        if elementName == "response" { cur = Entry() }
        if elementName == "collection" { cur?.isDir = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "href": if cur != nil && cur!.href.isEmpty { cur!.href = t }
        case "getcontentlength": cur?.size = Int64(t) ?? 0
        case "getlastmodified": cur?.modified = MultistatusParser.parseDate(t)
        case "response":
            if let c = cur { entries.append(c) }
            cur = nil
        default: break
        }
        text = ""
    }
}

/// Клиент WebDAV (Облако Mail.ru). Все вызовы блокирующие — работает на фоновой очереди движка.
final class WebDAVClient {
    private let base: String
    private let auth: String
    private let session: URLSession

    init(server: String, email: String, password: String) {
        var b = server.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        base = b
        auth = "Basic " + Data("\(email):\(password)".utf8).base64EncodedString()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 6 * 3600
        session = URLSession(configuration: cfg)
    }

    deinit { session.finishTasksAndInvalidate() }

    // MARK: - Низкий уровень

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private func url(_ path: String, dir: Bool) -> URL? {
        let e = path.split(separator: "/", omittingEmptySubsequences: true).map {
            String($0).addingPercentEncoding(withAllowedCharacters: WebDAVClient.unreserved) ?? String($0)
        }.joined(separator: "/")
        return URL(string: base + "/" + e + (dir && !e.isEmpty ? "/" : ""))
    }

    private func send(_ req: URLRequest) throws -> (Data, Int) {
        var attempt = 0
        while true {
            let sem = DispatchSemaphore(value: 0)
            var out: (Data?, URLResponse?, Error?) = (nil, nil, nil)
            session.dataTask(with: req) { d, r, e in out = (d, r, e); sem.signal() }.resume()
            sem.wait()
            if let e = out.2 {
                attempt += 1
                if attempt < 3 { Thread.sleep(forTimeInterval: Double(attempt) * 2); continue }
                throw SyncError.network(e.localizedDescription)
            }
            let code = (out.1 as? HTTPURLResponse)?.statusCode ?? 0
            if (code == 429 || code >= 500) && attempt < 3 {
                attempt += 1
                Thread.sleep(forTimeInterval: Double(attempt) * 3)
                continue
            }
            if code == 401 { throw SyncError.unauthorized }
            return (out.0 ?? Data(), code)
        }
    }

    private func request(_ method: String, _ path: String, dir: Bool,
                         headers: [String: String] = [:], body: Data? = nil) throws -> (Data, Int) {
        guard let u = url(path, dir: dir) else { throw SyncError.bad("Некорректный путь: \(path)") }
        var req = URLRequest(url: u)
        req.httpMethod = method
        req.setValue(auth, forHTTPHeaderField: "Authorization")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body
        return try send(req)
    }

    private func text(_ d: Data) -> String {
        String((String(data: d, encoding: .utf8) ?? "?").prefix(160))
    }

    private static let propBody = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <propfind xmlns="DAV:"><prop><resourcetype/><getcontentlength/><getlastmodified/></prop></propfind>
        """.utf8)

    private func normalize(_ p: String) -> String {
        var s = p
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s.isEmpty ? "/" : s
    }

    /// href из ответа → путь вида "/A/B".
    private func hrefPath(_ href: String) -> String {
        var h = href
        if let r = h.range(of: "://") {
            h = String(h[r.upperBound...])
            if let slash = h.firstIndex(of: "/") { h = String(h[slash...]) } else { h = "/" }
        }
        return normalize(h.removingPercentEncoding ?? h)
    }

    private func propfind(_ path: String, depth: Int, dir: Bool) throws -> (entries: [MultistatusParser.Entry], code: Int) {
        let (d, c) = try request("PROPFIND", path, dir: dir,
                                 headers: ["Depth": depth < 0 ? "infinity" : String(depth), "Content-Type": "application/xml; charset=utf-8"],
                                 body: WebDAVClient.propBody)
        if c == 404 { return ([], 404) }
        guard c == 207 || c == 200 else { throw SyncError.http(c, text(d)) }
        let parser = MultistatusParser()
        let xml = XMLParser(data: d)
        xml.shouldProcessNamespaces = true
        xml.delegate = parser
        xml.parse()
        return (parser.entries, c)
    }

    // MARK: - Методы

    /// Проверка подключения: читает корень.
    func checkConnection() throws {
        _ = try propfind("/", depth: 0, dir: true)
    }

    /// Содержимое одной папки. nil — папки нет.
    func list(_ dir: String) throws -> [(name: String, item: RemoteItem)]? {
        let r = try propfind(dir, depth: 1, dir: true)
        if r.code == 404 { return nil }
        let me = normalize(dir)
        let prefix = me == "/" ? "/" : me + "/"
        var out: [(String, RemoteItem)] = []
        for e in r.entries {
            let path = hrefPath(e.href)
            if path == me || !path.hasPrefix(prefix) { continue }
            let name = String(path.dropFirst(prefix.count))
            if name.isEmpty || name.contains("/") { continue }
            out.append((name, RemoteItem(isDir: e.isDir, size: e.size, modified: e.modified ?? Date(), apiPath: path)))
        }
        return out
    }

    /// Рекурсивный список содержимого. Ключ — относительный путь (NFC). nil, если папки нет.
    /// Папки читаются по уровням, по несколько запросов одновременно (Облако отвечает небыстро).
    /// progress(папок прочитано, объектов найдено) вызывается из фоновых потоков.
    func listTree(root: String, progress: ((Int, Int) -> Void)? = nil) throws -> [String: RemoteItem]? {
        let rootPath = normalize(root)
        var result: [String: RemoteItem] = [:]
        var level = [rootPath]
        var folders = 0
        let lock = NSLock()
        let q = DispatchQueue.global(qos: .utility)
        while !level.isEmpty {
            var next: [String] = []
            var firstError: Error?
            var rootMissing = false
            let limiter = DispatchSemaphore(value: 4)   // больше — сервер начинает отвечать медленнее
            let group = DispatchGroup()
            for dir in level {
                lock.lock(); let stop = firstError != nil; lock.unlock()
                if stop { break }
                limiter.wait()
                group.enter()
                q.async {
                    defer { limiter.signal(); group.leave() }
                    do {
                        guard let items = try self.list(dir) else {
                            if dir == rootPath { lock.lock(); rootMissing = true; lock.unlock() }
                            return
                        }
                        lock.lock()
                        for (_, item) in items {
                            let rel = String(item.apiPath.dropFirst(rootPath == "/" ? 1 : rootPath.count + 1))
                            result[rel.precomposedStringWithCanonicalMapping] = item
                            if item.isDir { next.append(item.apiPath) }
                        }
                        folders += 1
                        let f = folders, n = result.count
                        lock.unlock()
                        progress?(f, n)
                    } catch {
                        lock.lock()
                        if firstError == nil { firstError = error }
                        lock.unlock()
                    }
                }
            }
            group.wait()
            if let e = firstError { throw e }
            if rootMissing { return nil }
            level = next
        }
        return result
    }

    /// Чтение всего дерева одним запросом (PROPFIND с Depth: infinity), если сервер это позволяет.
    /// Бросает ошибку, если не позволяет или ответ выглядит неполным, — тогда читаем по папкам.
    /// nil — самой папки нет.
    func listTreeFast(root: String, knownDirs: Set<String>,
                      progress: ((Int, Int) -> Void)? = nil) throws -> [String: RemoteItem]? {
        let key = "webdavInfinityFailedAt"
        let failedAt = UserDefaults.standard.double(forKey: key)
        if failedAt > 0 && Date().timeIntervalSince1970 - failedAt < 7 * 86400 {
            throw SyncError.bad("Depth: infinity не поддерживается")
        }
        let rootPath = normalize(root)
        func unsupported(_ why: String) -> SyncError {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: key)
            return SyncError.bad("Depth: infinity: " + why)
        }
        // Пробный запрос: одна попытка и короткий тайм-аут — сервер может просто не отвечать на такой запрос.
        guard let u = url(rootPath, dir: true) else { throw SyncError.bad("Некорректный путь") }
        var req = URLRequest(url: u)
        req.httpMethod = "PROPFIND"
        req.timeoutInterval = 60      // законное долгое чтение дерева успеет; раз в неделю потерять минуту — не страшно
        req.setValue(auth, forHTTPHeaderField: "Authorization")
        req.setValue("infinity", forHTTPHeaderField: "Depth")
        req.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = WebDAVClient.propBody
        let sem = DispatchSemaphore(value: 0)
        var out: (Data?, URLResponse?, Error?) = (nil, nil, nil)
        session.dataTask(with: req) { d, r, e in out = (d, r, e); sem.signal() }.resume()
        sem.wait()
        let code = (out.1 as? HTTPURLResponse)?.statusCode ?? 0
        if let e = out.2 as? URLError {
            // настоящий обрыв связи — это не «не поддерживается»
            if [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
                .dnsLookupFailed].contains(e.code) { throw SyncError.network(e.localizedDescription) }
            throw unsupported("нет ответа за 60 с")
        }
        if out.2 != nil || code == 0 { throw unsupported("нет ответа") }
        if code == 401 { throw SyncError.unauthorized }
        if code == 404 { return nil }
        guard code == 207 || code == 200 else { throw unsupported("код \(code)") }
        let parser = MultistatusParser()
        let xml = XMLParser(data: out.0 ?? Data())
        xml.shouldProcessNamespaces = true
        xml.delegate = parser
        xml.parse()
        let r = (entries: parser.entries, code: code)
        if r.code == 404 { return nil }

        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        var result: [String: RemoteItem] = [:]
        var nested = false
        for e in r.entries {
            let path = hrefPath(e.href)
            if path == rootPath || !path.hasPrefix(prefix) { continue }
            let rel = String(path.dropFirst(prefix.count)).precomposedStringWithCanonicalMapping
            if rel.isEmpty { continue }
            if rel.contains("/") { nested = true }
            result[rel] = RemoteItem(isDir: e.isDir, size: e.size, modified: e.modified ?? Date(), apiPath: path)
        }
        progress?(result.values.filter { $0.isDir }.count, result.count)
        // Сервер мог молча прочитать только один уровень — тогда вложенного нет вообще.
        if !nested && !knownDirs.isEmpty { throw unsupported("ответ без вложенных папок") }
        // Если известные нам папки массово «пропали», ответ неполный.
        let gone = knownDirs.filter { result[$0] == nil }.count
        if gone > 5 && gone * 20 > knownDirs.count { throw SyncError.bad("Depth: infinity: ответ неполный") }
        return result
    }

    /// Имена подпапок — для дерева выбора в настройках.
    func listDirs(_ path: String) throws -> [String] {
        let items = try list(path) ?? []
        return items.filter { $0.item.isDir }.map { $0.name }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Метаданные файла; nil, если его нет.
    func stat(_ path: String) throws -> RemoteItem? {
        let r = try propfind(path, depth: 0, dir: false)
        guard let e = r.entries.first else { return nil }
        return RemoteItem(isDir: e.isDir, size: e.size, modified: e.modified ?? Date(), apiPath: normalize(path))
    }

    func makeDir(_ path: String) throws {
        let (d, c) = try request("MKCOL", path, dir: true)
        if c == 201 || c == 405 { return }       // 405 — уже существует
        throw SyncError.http(c, text(d))
    }

    func ensureDir(_ path: String) throws {
        var cur = ""
        for comp in path.split(separator: "/") {
            cur += "/" + comp
            try makeDir(cur)
        }
    }

    /// Переименование или перенос папки одним запросом (WebDAV MOVE): содержимое остаётся на месте.
    func move(_ from: String, to: String, isDir: Bool) throws {
        guard let dest = url(to, dir: isDir) else { throw SyncError.bad("Некорректный путь") }
        let parent = (to as NSString).deletingLastPathComponent
        if !parent.isEmpty && parent != "/" { try ensureDir(parent) }
        let (d, c) = try request("MOVE", from, dir: isDir, headers: ["Destination": dest.absoluteString, "Overwrite": "F"])
        if c == 201 || c == 204 { return }
        throw SyncError.http(c, text(d))
    }

    func delete(_ path: String, isDir: Bool) throws {
        let (d, c) = try request("DELETE", path, dir: isDir)
        if c == 200 || c == 204 || c == 404 { return }
        throw SyncError.http(c, text(d))
    }

    func download(_ path: String, to staging: URL) throws {
        guard let u = url(path, dir: false) else { throw SyncError.bad("Некорректный путь") }
        var req = URLRequest(url: u)
        req.setValue(auth, forHTTPHeaderField: "Authorization")
        let sem = DispatchSemaphore(value: 0)
        var err: Error?
        var status = 0
        session.downloadTask(with: req) { tmp, resp, e in
            err = e
            status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if let tmp = tmp, e == nil, status == 200 {
                do {
                    try? FileManager.default.removeItem(at: staging)
                    try FileManager.default.moveItem(at: tmp, to: staging)
                } catch { err = error }
            }
            sem.signal()
        }.resume()
        sem.wait()
        if let e = err { throw SyncError.network(e.localizedDescription) }
        if status == 401 { throw SyncError.unauthorized }
        if status != 200 { throw SyncError.http(status, "ошибка скачивания") }
    }

    func upload(_ file: URL, to path: String) throws {
        guard let u = url(path, dir: false) else { throw SyncError.bad("Некорректный путь") }
        // Сервер при большой нагрузке иногда не отвечает вовремя; PUT безопасно повторять, поэтому до трёх попыток.
        var attempt = 0
        while true {
            var req = URLRequest(url: u)
            req.httpMethod = "PUT"
            req.setValue(auth, forHTTPHeaderField: "Authorization")
            let sem = DispatchSemaphore(value: 0)
            var err: Error?
            var status = 0
            session.uploadTask(with: req, fromFile: file) { _, resp, e in
                err = e
                status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                sem.signal()
            }.resume()
            sem.wait()
            if (err != nil || status == 429 || status >= 500) && attempt < 2 {
                attempt += 1
                Thread.sleep(forTimeInterval: Double(attempt) * 4)
                continue
            }
            if let e = err { throw SyncError.network(e.localizedDescription) }
            if status == 401 { throw SyncError.unauthorized }
            if ![200, 201, 204].contains(status) { throw SyncError.http(status, "ошибка загрузки") }
            return
        }
    }
}
