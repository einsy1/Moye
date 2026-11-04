import Foundation
import Security

struct NASConfig: Codable {
    var address: String
    var username: String
    var folder: String
    var allowHTTP: Bool
    var fingerprint: String { address + "|" + username + "|" + folder }
    func directory() throws -> URL {
        guard var url = URL(string: address), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && allowHTTP) else {
            throw DAVError.message("请填写有效的 HTTPS WebDAV 地址；HTTP 仅在明确启用后可用。")
        }
        for component in folder.split(separator: "/") {
            guard component != ".", component != ".." else { throw DAVError.message("目录不能包含 . 或 ..") }
            url.appendPathComponent(String(component), isDirectory: true)
        }
        if !url.absoluteString.hasSuffix("/") { url = URL(string: url.absoluteString + "/")! }
        return url
    }
}
enum DAVError: LocalizedError {
    case message(String), status(Int), network(String, Bool)
    var errorDescription: String? {
        switch self {
        case .message(let text), .network(let text, _): return text
        case .status(let code):
            switch code {
            case 301,302,303,307,308: return "服务器要求重定向，请在配置中填写最终 WebDAV 地址（\(code)）。"
            case 401,403: return "NAS 拒绝访问，请检查账号、密码和目录权限（\(code)）。"
            case 404,409: return "NAS 目录不存在，请先建立目录并检查路径（\(code)）。"
            case 412: return "同名文件已存在或远程版本已变化，请另存副本。"
            case 507: return "NAS 存储空间不足。"
            default: return "WebDAV 请求失败（\(code)）。"
            }
        }
    }
    var retryable: Bool { if case .network(_, let retry) = self { return retry }; if case .status(let c) = self { return c == 408 || c == 429 || c >= 500 && c != 507 }; return false }
}
final class DAVRedirectGuard: NSObject, URLSessionDataDelegate {
    let limit: Int
    var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var buffer = Data()
    private var response: HTTPURLResponse?
    private var rejection: Error?
    init(limit: Int) { self.limit = limit }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Never forward credentials through a redirect.
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            rejection = DAVError.message("NAS 返回了无效响应。"); completionHandler(.cancel); return
        }
        self.response = http
        guard (200..<300).contains(http.statusCode) else {
            rejection = DAVError.status(http.statusCode); completionHandler(.cancel); return
        }
        if response.expectedContentLength > Int64(limit) {
            rejection = DAVError.message("NAS 响应超过大小限制，已停止下载（文稿 10 MB，目录 4 MB）。")
            completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard rejection == nil else { return }
        guard data.count <= limit - buffer.count else {
            rejection = DAVError.message("NAS 响应超过大小限制，已停止下载（文稿 10 MB，目录 4 MB）。")
            dataTask.cancel(); return
        }
        buffer.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let continuation = continuation else { return }
        self.continuation = nil
        if let error = rejection ?? error { continuation.resume(throwing: error) }
        else if let response = response { continuation.resume(returning: (buffer, response)) }
        else { continuation.resume(throwing: DAVError.message("NAS 返回了无效响应。")) }
    }
}
final class WebDAVClient {
    let config: NASConfig
    let password: String
    init(config: NASConfig, password: String) { self.config = config; self.password = password }
    private func singleRequest(_ method: String, url: URL, text: String? = nil, headers: [String: String] = [:], xml: String? = nil) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url); request.httpMethod = method
        request.timeoutInterval = 25
        request.setValue("Basic " + Data((config.username + ":" + password).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let text = text { request.httpBody = Data(text.utf8); request.setValue("text/markdown; charset=utf-8", forHTTPHeaderField: "Content-Type") }
        if let xml = xml { request.httpBody = Data(xml.utf8); request.setValue("application/xml; charset=utf-8", forHTTPHeaderField:"Content-Type") }
        let settings = URLSessionConfiguration.ephemeral
        settings.urlCache = nil; settings.httpCookieStorage = nil
        let receiver = DAVRedirectGuard(limit: method == "PROPFIND" ? 4_000_000 : method == "GET" ? LocalFileIO.maxBytes : 1_000_000)
        let session = URLSession(configuration: settings, delegate: receiver, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            receiver.continuation = continuation
            session.dataTask(with: request).resume()
        }
    }
    // Only read-only requests retry. A PUT may have succeeded before a connection loss.
    private func request(_ method: String, url: URL, text: String? = nil, headers: [String: String] = [:], xml: String? = nil) async throws -> (Data, HTTPURLResponse) {
        for attempt in 0..<3 {
            do { return try await singleRequest(method, url:url, text:text, headers:headers, xml:xml) }
            catch {
                let code = (error as? URLError)?.code
                let transient = [URLError.timedOut, .networkConnectionLost, .cannotConnectToHost, .secureConnectionFailed].contains(where: { $0 == code }) || (error as? DAVError)?.retryable == true
                if ["PROPFIND", "GET"].contains(method), transient, attempt < 2 {
                    try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 500_000_000)
                    continue
                }
                if let error = error as? URLError {
                    let reason: String
                    switch error.code {
                    case .secureConnectionFailed: reason = "HTTPS 握手被中断，尚未验证账号或目录。请检查外网端口映射、反向代理和网络链路。"
                    case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid: reason = "HTTPS 证书校验失败，请检查域名、证书链和有效期。"
                    case .timedOut: reason = "连接超时，请检查 NAS 外网访问是否可用。"
                    case .cannotFindHost, .dnsLookupFailed: reason = "无法解析 NAS 域名，请检查 DNS。"
                    case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost: reason = "网络连接不可用或被中断，请检查外网端口和网络连接。"
                    default: reason = "网络请求失败。"
                    }
                    throw DAVError.network(reason + "（网络错误 \(error.errorCode)）", [.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet].contains(error.code))
                }
                throw error
            }
        }
        throw DAVError.message("连接失败，请稍后重试。")
    }
    static let properties = """
    <?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:displayname/><d:getetag/></d:prop></d:propfind>
    """
    func test() async throws {
        let url = try config.directory()
        let (data, response) = try await request("PROPFIND", url: url, headers: ["Depth":"0"], xml: Self.properties)
        _ = try DAVListing.parse(data, response: response, directory: url, base: url)
    }
    func list(folder: String) async throws -> [DAVFolder] {
        try await listContents(folder: folder).folders
    }
    func listContents(folder: String) async throws -> DAVContents {
        var target = config; target.folder = folder
        var root = config; root.folder = ""
        let url = try target.directory()
        let (data, response) = try await request("PROPFIND", url: url, headers:["Depth":"1"], xml:Self.properties)
        return try DAVListing.parseContents(data, response:response, directory:url, base:root.directory())
    }
    func download(path: String) async throws -> (name: String, folder: String, text: String, etag: String?) {
        let parts = path.split(separator: "/").map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains("\0") }),
              let name = parts.last, DAVListing.readableExtensions.contains(URL(fileURLWithPath: name).pathExtension.lowercased()) else {
            throw DAVError.message("请选择有效的 Markdown 或文本文件。")
        }
        var root = config; root.folder = ""
        var url = try root.directory()
        for part in parts.dropLast() { url.appendPathComponent(part, isDirectory: true) }
        url.appendPathComponent(name, isDirectory: false)
        let (data, response) = try await request("GET", url: url)
        guard data.count <= 10_000_000 else { throw DAVError.message("远程文稿过大，无法在编辑器中直接打开。") }
        guard let text = String(data: data, encoding: .utf8) else { throw DAVError.message("远程文件不是有效的 UTF-8 文本。") }
        return (name: name, folder: parts.dropLast().joined(separator: "/"), text: text, etag: response.value(forHTTPHeaderField: "ETag"))
    }
    func upload(name: String, text: String, etag: String?, updating: Bool, folder: String? = nil) async throws -> String? {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), name != ".", name != ".." else { throw DAVError.message("文件名不能包含路径分隔符。") }
        var target = config
        if let folder = folder { target.folder = folder }
        let url = try target.directory().appendingPathComponent(name)
        var headers: [String: String] = [:]
        if updating {
            guard let etag = etag, !etag.hasPrefix("W/"), etag.hasPrefix("\"") else { throw DAVError.message("服务器未提供可用于安全更新的 ETag，请另存副本。") }
            headers["If-Match"] = etag
        } else { headers["If-None-Match"] = "*" }
        let (_, response) = try await request("PUT", url: url, text: text, headers: headers)
        return response.value(forHTTPHeaderField: "ETag")
    }
}
enum NASKeychain {
    static func read() -> String? {
        let query: [String: Any] = [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:"com.neil.moye.webdav", kSecAttrAccount as String:"default", kSecReturnData as String:true, kSecMatchLimit as String:kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ password: String) throws {
        let query: [String: Any] = [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:"com.neil.moye.webdav", kSecAttrAccount as String:"default"]
        let attributes: [String: Any] = [kSecValueData as String:Data(password.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { var insert = query; insert.merge(attributes) { _, new in new }; insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly; status = SecItemAdd(insert as CFDictionary, nil) }
        guard status == errSecSuccess else { throw DAVError.message("无法保存到系统钥匙串（\(status)）。") }
    }
}

struct DAVFolder: Codable {
    let name: String
    let path: String
}
struct DAVFile: Codable {
    let name: String
    let path: String
    let etag: String?
}
struct DAVContents: Codable {
    let folders: [DAVFolder]
    let files: [DAVFile]
}
// Interpret namespace-aware multistatus replies; never derive paths from NAS disk names.
final class DAVListing: NSObject, XMLParserDelegate {
    static let readableExtensions: Set<String> = ["md", "markdown", "mdown", "txt"]
    struct Entry { var href = ""; var name = ""; var etag = ""; var collection = false; var valid = false; var status = 0 }
    var entries: [Entry] = []
    var current = Entry()
    var stack: [String] = []
    var text = ""
    var propName = "", propEtag = "", propCollection = false, propStatus = 0
    var isMultistatus = false
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        let name = namespaceURI == "DAV:" ? elementName : "!" + elementName
        stack.append(name); text = ""
        if stack == ["multistatus"] { isMultistatus = true }
        if stack == ["multistatus","response"] { current = Entry() }
        if name == "propstat" { propName = ""; propEtag = ""; propCollection = false; propStatus = 0 }
        if stack.suffix(3) == ["prop","resourcetype","collection"] { propCollection = true }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = stack.last ?? ""
        if name == "href", stack.count == 3 { current.href = text.trimmingCharacters(in:.whitespacesAndNewlines) }
        if name == "displayname", stack.contains("prop") { propName = text }
        if name == "getetag", stack.contains("prop") { propEtag = text.trimmingCharacters(in:.whitespacesAndNewlines) }
        if name == "status" {
            let code = Int(text.split(separator:" ").dropFirst().first ?? "") ?? 0
            if stack.contains("propstat") { propStatus = code } else { current.status = code }
        }
        if name == "propstat", (200..<300).contains(propStatus) {
            current.valid = true; current.collection = current.collection || propCollection
            if !propName.isEmpty { current.name = propName }
            if !propEtag.isEmpty { current.etag = propEtag }
        }
        if stack == ["multistatus","response"] { entries.append(current) }
        _ = stack.popLast(); text = ""
    }
    static func components(_ url: URL) -> [String]? {
        guard let encoded = URLComponents(url:url,resolvingAgainstBaseURL:true)?.percentEncodedPath else { return nil }
        var result: [String] = []
        for part in encoded.split(separator:"/") {
            guard let decoded = String(part).removingPercentEncoding, decoded != ".", decoded != "..", !decoded.contains("/"), !decoded.contains("\\"), !decoded.contains("\0") else { return nil }
            result.append(decoded)
        }
        return result
    }
    static func parse(_ data: Data, response: HTTPURLResponse, directory: URL, base: URL) throws -> [DAVFolder] {
        try parseContents(data, response: response, directory: directory, base: base).folders
    }
    static func parseContents(_ data: Data, response: HTTPURLResponse, directory: URL, base: URL) throws -> DAVContents {
        guard response.statusCode == 207 else { throw DAVError.message("地址未返回 WebDAV 目录响应，请检查是否填写了网页管理地址。") }
        guard data.count <= 4_000_000 else { throw DAVError.message("目录响应过大，请选择更具体的 WebDAV 入口。") }
        let content = String(decoding:data,as:UTF8.self).uppercased()
        guard !content.contains("<!DOCTYPE"), !content.contains("<!ENTITY") else { throw DAVError.message("目录响应包含不支持的 XML 实体。") }
        let delegate = DAVListing(), parser = XMLParser(data:data)
        parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), delegate.isMultistatus, let parent = components(directory), let baseParts = components(base) else { throw DAVError.message("无法解析 WebDAV 目录响应。") }
        var selfFound = false, selfStatus = 0, folders: [DAVFolder] = [], files: [DAVFile] = [], seen = Set<String>()
        for entry in delegate.entries {
            guard let url = URL(string:entry.href,relativeTo:directory)?.absoluteURL,
                url.scheme?.lowercased() == directory.scheme?.lowercased(), url.host?.lowercased() == directory.host?.lowercased(),
                (url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)) == (directory.port ?? (directory.scheme?.lowercased() == "https" ? 443 : 80)),
                url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, let parts = components(url) else { continue }
            if parts == parent { selfFound = entry.valid && entry.collection; selfStatus = entry.status; continue }
            guard entry.valid, parts.count == parent.count + 1, Array(parts.prefix(parent.count)) == parent, Array(parts.prefix(baseParts.count)) == baseParts else { continue }
            let path = parts.dropFirst(baseParts.count).joined(separator:"/")
            let label = entry.name.isEmpty ? parts.last! : entry.name
            if entry.collection {
                if seen.insert("d:" + path).inserted { folders.append(DAVFolder(name:label, path:path)) }
            } else if readableExtensions.contains(URL(fileURLWithPath:parts.last!).pathExtension.lowercased()) {
                if seen.insert("f:" + path).inserted { files.append(DAVFile(name:parts.last!, path:path, etag:entry.etag.isEmpty ? nil : entry.etag)) }
            }
        }
        guard selfFound else {
            if selfStatus >= 400 { throw DAVError.status(selfStatus) }
            throw DAVError.message("服务器未确认该地址为可访问的 WebDAV 文件夹；请检查入口、目录和权限。")
        }
        return DAVContents(
            folders: folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            files: files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        )
    }
}
