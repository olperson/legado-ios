import CryptoKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct WebDAVRemoteSnapshot: Equatable, Sendable {
    public let data: Data
    public let etag: String?
}

public struct WebDAVBackupFile: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let date: Date
    public let size: Int64?
    public var isLegacySnapshot: Bool { name == "legado-sync.json" }

    fileprivate let etag: String?
    fileprivate let modified: String?
}

public enum WebDAVSyncDirection: Equatable, Sendable {
    case upload, download, unchanged, conflict
}

public enum WebDAVSyncError: LocalizedError, Equatable {
    case invalidDirectory, invalidUsername, unauthorized, forbidden, missingDirectory
    case redirected, remoteChanged, missingStrongETag, unexpectedResponse
    case incompleteBackup(expected: Int64, received: UInt64)
    case httpStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidDirectory: "请输入 WebDAV 目录的完整 HTTP 或 HTTPS 地址。"
        case .invalidUsername: "请检查 WebDAV 用户名。"
        case .unauthorized: "WebDAV 身份验证失败，请检查用户名和密码。"
        case .forbidden: "WebDAV 拒绝访问，请检查目录权限。"
        case .missingDirectory: "WebDAV 无法创建或访问备份目录，请检查目录地址和写入权限。"
        case .redirected: "服务器返回了重定向，请填写最终的 WebDAV 目录地址。"
        case .remoteChanged: "云端文件已发生变化，请重新同步。"
        case .missingStrongETag: "服务器未提供可用于安全覆盖的强 ETag。请稍后重试，也可以从云端下载。"
        case .unexpectedResponse: "服务器返回了意外内容，请检查 WebDAV 目录地址。"
        case .incompleteBackup(let expected, let received): "下载文件长度与备份不一致（预期 \(expected) 字节，实际 \(received) 字节），请刷新备份列表后重试。"
        case .httpStatus(let code): "WebDAV 请求失败（HTTP \(code)）。"
        }
    }
}

public final class WebDAVSync: Sendable {
    public let fileURL: URL
    private let directoryURL: URL
    private let authorization: String?
    private let session: URLSession

    public convenience init(directoryURL: String, username: String, password: String) throws {
        try self.init(directoryURL: directoryURL, username: username, password: password,
                      configuration: .ephemeral)
    }

    init(directoryURL: String, username: String, password: String, configuration: URLSessionConfiguration) throws {
        let input = directoryURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let address = Self.encodedAddress(input),
              var parts = URLComponents(string: address),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else {
            throw WebDAVSyncError.invalidDirectory
        }
        guard !username.contains(":"), !username.isEmpty || password.isEmpty else {
            throw WebDAVSyncError.invalidUsername
        }
        for component in parts.percentEncodedPath.split(separator: "/") {
            guard let decoded = String(component).removingPercentEncoding, Self.isPathComponent(decoded) else {
                throw WebDAVSyncError.invalidDirectory
            }
        }
        if !parts.percentEncodedPath.hasSuffix("/") { parts.percentEncodedPath += "/" }
        guard let directory = parts.url else { throw WebDAVSyncError.invalidDirectory }
        self.directoryURL = directory
        fileURL = directory.appendingPathComponent("legado-sync.json", isDirectory: false)
        authorization = username.isEmpty ? nil : "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: WebDAVSessionDelegate(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    public static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func direction(local: Data, localIsEmpty: Bool, remoteData: Data?,
                                 remoteIsEmpty: Bool = false, base: String?) -> WebDAVSyncDirection {
        guard let remoteData else { return base == nil ? .upload : .conflict }
        if local == remoteData { return .unchanged }
        guard let base else {
            if localIsEmpty { return .download }
            return remoteIsEmpty ? .upload : .conflict
        }
        if fingerprint(local) == base { return .download }
        if fingerprint(remoteData) == base { return .upload }
        return .conflict
    }

    public func fetch() async throws -> WebDAVRemoteSnapshot? {
        let (data, response) = try await send(request(method: "GET"))
        switch response.statusCode {
        case 404:
            return nil
        case 200:
            guard !Self.isHTML(response, data: data), !data.isEmpty else {
                throw WebDAVSyncError.unexpectedResponse
            }
            return WebDAVRemoteSnapshot(data: data, etag: response.value(forHTTPHeaderField: "ETag"))
        default:
            throw Self.error(response)
        }
    }

    public func verifyUnchanged(_ expected: WebDAVRemoteSnapshot?) async throws {
        guard try await fetch() == expected else { throw WebDAVSyncError.remoteChanged }
    }

    public func upload(_ data: Data, replacing remote: WebDAVRemoteSnapshot?) async throws {
        var put = request(method: "PUT")
        put.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if let remote {
            guard let tag = remote.etag, Self.isStrongETag(tag) else { throw WebDAVSyncError.missingStrongETag }
            put.setValue(tag, forHTTPHeaderField: "If-Match")
        } else {
            put.setValue("*", forHTTPHeaderField: "If-None-Match")
        }
        put.httpBody = data
        let (body, response) = try await creatingDirectoryIfMissing { try await send(put) }
        switch response.statusCode {
        case 200, 201, 204:
            // Some DAV servers return an HTML "Created" page. Verify the resource
            // before accepting it, since a login page can also arrive with HTTP 200.
            if Self.isHTML(response, data: body) {
                guard try await fetch()?.data == data else { throw WebDAVSyncError.unexpectedResponse }
            }
        case 404, 409:
            throw WebDAVSyncError.missingDirectory
        default:
            throw Self.error(response)
        }
    }

    private func directoryQuery(depth: Int) -> URLRequest {
        var query = request(method: "PROPFIND", url: directoryURL)
        query.setValue(String(depth), forHTTPHeaderField: "Depth")
        query.setValue("application/xml", forHTTPHeaderField: "Accept")
        query.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        query.httpBody = Data("""
            <D:propfind xmlns:D="DAV:"><D:prop><D:resourcetype/><D:getlastmodified/>
            <D:getcontentlength/><D:getetag/><D:creationdate/></D:prop></D:propfind>
            """.utf8)
        return query
    }

    public func listBackups(includeOtherArchives: Bool = false) async throws -> [WebDAVBackupFile] {
        let query = directoryQuery(depth: 1)
        let (xml, response) = try await creatingDirectoryIfMissing { try await send(query) }
        guard response.statusCode == 207 else { throw Self.error(response) }
        let entries = try WebDAVListing.parse(xml)
        var files: [String: WebDAVBackupFile] = [:]
        let httpDate = Self.dateFormatter("EEE, dd MMM yyyy HH:mm:ss zzz")
        let timestamp = Self.dateFormatter(Self.timestampFormat)
        let isoDate = ISO8601DateFormatter()
        let fractionalDate = ISO8601DateFormatter()
        fractionalDate.formatOptions.insert(.withFractionalSeconds)
        for entry in entries {
            guard entry.properties["collection"] == nil,
                  let name = backupName(href: entry.href),
                  includeOtherArchives || name == "legado-sync.json" || name.hasPrefix(Self.backupPrefix) else { continue }
            let modified = entry.properties["getlastmodified"].flatMap(httpDate.date(from:))
            let stamp = name.dropFirst(Self.backupPrefix.count).prefix(19)
            let created = name.hasPrefix(Self.backupPrefix) && stamp.count == 19 ? timestamp.date(from: String(stamp)) : nil
            let creationDate = entry.properties["creationdate"].flatMap { isoDate.date(from: $0) ?? fractionalDate.date(from: $0) }
            let date = created ?? modified ?? creationDate ?? .distantPast
            files[name] = WebDAVBackupFile(name: name, date: date,
                                           size: entry.properties["getcontentlength"].flatMap(Int64.init),
                                           etag: entry.properties["getetag"].flatMap(Self.listedETag), modified: modified.map(httpDate.string(from:)))
        }
        return files.values.sorted { $0.date == $1.date ? $0.name > $1.name : $0.date > $1.date }
    }

    public static func newBackupName(at date: Date = Date()) -> String {
        let stamp = dateFormatter(timestampFormat).string(from: date)
        return backupPrefix + stamp + "-" + UUID().uuidString + ".zip"
    }

    @discardableResult
    public func uploadBackup(from file: URL) async throws -> WebDAVBackupFile {
        let date = Date()
        let name = Self.newBackupName(at: date)
        let url = directoryURL.appendingPathComponent(name)
        // A URL can cache resource values across writes to the same path on Apple platforms.
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard let fileSize = attributes[.size] as? NSNumber else { throw WebDAVSyncError.unexpectedResponse }
        let size = fileSize.int64Value
        // Discover missing collections before streaming what can be several gigabytes.
        let (_, directory) = try await send(directoryQuery(depth: 0))
        switch directory.statusCode {
        case 404, 409: try await createCollection(directoryURL)
        // A write-only DAV account may prohibit PROPFIND but still allow the conditional PUT.
        case 207, 403, 405, 501: break
        default: throw Self.error(directory)
        }
        var put = request(method: "PUT", url: url)
        put.setValue("application/zip", forHTTPHeaderField: "Content-Type")
        put.setValue("*", forHTTPHeaderField: "If-None-Match")
        let (body, response) = try await creatingDirectoryIfMissing {
            try await perform { try await session.upload(for: put, fromFile: file) }
        }
        guard [200, 201, 204].contains(response.statusCode) else { throw Self.error(response) }
        let backup = WebDAVBackupFile(name: name, date: date, size: size,
                                      etag: response.value(forHTTPHeaderField: "ETag"), modified: nil)
        if Self.isHTML(response, data: body) {
            // A login page may return 200, while a successful PUT may return an HTML receipt.
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: copy) }
            try await downloadBackup(backup, to: copy)
            guard FileManager.default.contentsEqual(atPath: file.path, andPath: copy.path) else {
                throw WebDAVSyncError.unexpectedResponse
            }
        }
        return backup
    }

    public func downloadBackup(_ backup: WebDAVBackupFile, to file: URL) async throws {
        let url = directoryURL.appendingPathComponent(backup.name)
        var get = request(method: "GET", url: url)
        get.setValue(backup.isLegacySnapshot ? "application/json" : "application/zip, application/octet-stream",
                     forHTTPHeaderField: "Accept")
        if let tag = backup.etag, Self.isStrongETag(tag) {
            get.setValue(tag, forHTTPHeaderField: "If-Match")
        } else if let modified = backup.modified {
            get.setValue(modified, forHTTPHeaderField: "If-Unmodified-Since")
        }
        let (download, response) = try await perform { try await session.download(for: get) }
        defer { try? FileManager.default.removeItem(at: download) }
        guard response.statusCode != 404 else { throw WebDAVSyncError.remoteChanged }
        guard response.statusCode == 200 else { throw Self.error(response) }
        let handle = try FileHandle(forReadingFrom: download)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 64) ?? Data()
        guard !prefix.isEmpty, !Self.isHTML(response, data: prefix),
              backup.isLegacySnapshot || prefix.starts(with: [0x50, 0x4b, 0x03, 0x04]) else {
            throw WebDAVSyncError.unexpectedResponse
        }
        if let expected = backup.size {
            let received = try handle.seekToEnd()
            guard received == expected else { throw WebDAVSyncError.incompleteBackup(expected: expected, received: received) }
        }
        try FileManager.default.moveItem(at: download, to: file)
    }

    private static let backupPrefix = "legado-ios-"
    private static let timestampFormat = "yyyyMMdd'T'HHmmssSSS'Z'"

    private static func dateFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }

    // Preserve existing percent escapes when a user or server also supplies literal Unicode or spaces.
    private static func encodedAddress(_ address: String) -> String? {
        address.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed.union(CharacterSet(charactersIn: "%#[]")))
    }

    private static func isPathComponent(_ component: String) -> Bool {
        !component.isEmpty && component != "." && component != ".." &&
            !component.contains("/") && !component.contains("\\") &&
            component.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private func backupName(href: String) -> String? {
        guard let address = Self.encodedAddress(href),
              let url = URL(string: address, relativeTo: directoryURL)?.absoluteURL,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let directory = URLComponents(url: directoryURL, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == directory.scheme?.lowercased(),
              parts.host?.lowercased() == directory.host?.lowercased(),
              (parts.port ?? (parts.scheme?.lowercased() == "https" ? 443 : 80))
                == (directory.port ?? (directory.scheme?.lowercased() == "https" ? 443 : 80)),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              !parts.percentEncodedPath.hasSuffix("/") else { return nil }
        let components = parts.percentEncodedPath.split(separator: "/").map { String($0).removingPercentEncoding }
        let parent = directory.percentEncodedPath.split(separator: "/").map { String($0).removingPercentEncoding }
        guard components.dropLast().elementsEqual(parent), let name = components.last ?? nil,
              Self.isPathComponent(name), name == "legado-sync.json" || name.lowercased().hasSuffix(".zip") else { return nil }
        return name
    }

    private func creatingDirectoryIfMissing(_ operation: () async throws -> (Data, HTTPURLResponse)) async throws
        -> (Data, HTTPURLResponse) {
        let result = try await operation()
        guard [404, 409].contains(result.1.statusCode) else { return result }
        try await createCollection(directoryURL)
        return try await operation()
    }

    private func createCollection(_ directory: URL) async throws {
        guard var parts = URLComponents(url: directory, resolvingAgainstBaseURL: false),
              !parts.percentEncodedPath.split(separator: "/").isEmpty else { throw WebDAVSyncError.missingDirectory }
        let mkcol = request(method: "MKCOL", url: directory)
        var (_, response) = try await send(mkcol)
        if [404, 409].contains(response.statusCode) {
            var segments = parts.percentEncodedPath.split(separator: "/")
            segments.removeLast()
            guard !segments.isEmpty else { throw WebDAVSyncError.missingDirectory }
            parts.percentEncodedPath = "/" + segments.joined(separator: "/") + "/"
            guard let parent = parts.url else { throw WebDAVSyncError.invalidDirectory }
            try await createCollection(parent)
            (_, response) = try await send(mkcol)
        }
        // RFC 4918 specifies 405 when the collection already exists (including a concurrent MKCOL).
        guard [200, 201, 204, 405].contains(response.statusCode) else { throw Self.error(response) }
    }

    private func request(method: String, url: URL? = nil) -> URLRequest {
        var request = URLRequest(url: url ?? fileURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = method
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json, */*;q=0.5", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await perform { try await session.data(for: request) }
    }

    private func perform<T>(_ operation: () async throws -> (T, URLResponse)) async throws -> (T, HTTPURLResponse) {
        do {
            let (data, response) = try await operation()
            guard let http = response as? HTTPURLResponse else { throw WebDAVSyncError.unexpectedResponse }
            return (data, http)
        } catch let error as URLError where !Task.isCancelled &&
            [.userAuthenticationRequired, .userCancelledAuthentication, .cancelled].contains(error.code) {
            // Rejecting a repeated credential challenge can cancel the request
            // instead of delivering the server's 401 as an HTTP response.
            throw WebDAVSyncError.unauthorized
        }
    }

    // Some DAV implementations expose the opaque tag without HTTP's surrounding quotes in XML.
    // Use it only for a conditional read. Mutable JSON writes still require a strong HTTP ETag.
    private static func listedETag(_ tag: String) -> String? {
        if isStrongETag(tag) { return tag }
        let quoted = "\"" + tag + "\""
        guard !tag.isEmpty, tag != "*", !tag.hasPrefix("W/"), !tag.contains(","), isStrongETag(quoted) else {
            return nil
        }
        return quoted
    }

    private static func isStrongETag(_ tag: String) -> Bool {
        let bytes = tag.utf8
        guard bytes.count >= 2, bytes.first == 34, bytes.last == 34 else { return false }
        return bytes.dropFirst().dropLast().allSatisfy { $0 == 33 || (35...126).contains($0) || $0 >= 128 }
    }

    private static func isHTML(_ response: HTTPURLResponse, data: Data) -> Bool {
        if ["text/html", "application/xhtml+xml"].contains(response.mimeType?.lowercased() ?? "") { return true }
        return data.first(where: { ![9, 10, 13, 32].contains($0) }) == 60
    }

    private static func error(_ response: HTTPURLResponse) -> WebDAVSyncError {
        switch response.statusCode {
        case 200..<300: .unexpectedResponse
        case 300..<400: .redirected
        case 401: .unauthorized
        case 403: .forbidden
        case 404, 409: .missingDirectory
        case 412: .remoteChanged
        default: .httpStatus(response.statusCode)
        }
    }
}

private final class WebDAVSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest:
            // Basic credentials, if configured, were sent with the original request.
            completionHandler(.rejectProtectionSpace, nil)
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Keep credentials, conditional headers and the PUT body at the configured resource.
        completionHandler(nil)
    }
}

/// Parse only direct DAV properties with a successful propstat. A multistatus may report
/// missing properties with a separate 404 for the same resource.
private final class WebDAVListing: NSObject, XMLParserDelegate {
    struct Entry {
        var href = ""
        var properties: [String: String] = [:]
    }

    private var entries: [Entry] = []
    private var path: [String] = []
    private var text = ""
    private var entry = Entry()
    private var responseOK = true
    private var properties: [String: String] = [:]
    private var propertyOK = false
    private var foundMultistatus = false

    static func parse(_ data: Data) throws -> [Entry] {
        let delegate = WebDAVListing()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.foundMultistatus else { throw WebDAVSyncError.unexpectedResponse }
        return delegate.entries
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        guard path.count < 64 else { parser.abortParsing(); return }
        path.append(namespaceURI == "DAV:" ? elementName : "")
        text = ""
        switch path {
        case ["multistatus"]:
            foundMultistatus = true
        case ["multistatus", "response"]:
            entry = Entry()
            responseOK = true
        case ["multistatus", "response", "propstat"]:
            properties.removeAll(keepingCapacity: true)
            propertyOK = false
        case ["multistatus", "response", "propstat", "prop", "resourcetype", "collection"]:
            properties["collection"] = "true"
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?,
                systemID: String?) {
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch path {
        case ["multistatus", "response", "href"]:
            entry.href = value
        case ["multistatus", "response", "status"]:
            responseOK = Self.succeeds(value)
        case ["multistatus", "response", "propstat", "status"]:
            propertyOK = Self.succeeds(value)
        case ["multistatus", "response", "propstat"]:
            if propertyOK { entry.properties.merge(properties) { _, new in new } }
        case ["multistatus", "response"]:
            if responseOK, !entry.href.isEmpty, !entry.properties.isEmpty { entries.append(entry) }
        default:
            if path.dropLast().elementsEqual(["multistatus", "response", "propstat", "prop"]),
               let key = path.last, ["getetag", "getlastmodified", "creationdate", "getcontentlength", "resourcetype"].contains(key) {
                properties[key] = value
            }
        }
        path.removeLast()
        text = ""
    }

    private static func succeeds(_ status: String) -> Bool {
        let fields = status.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2, let code = Int(fields[1]) else { return false }
        return (200..<300).contains(code)
    }
}
