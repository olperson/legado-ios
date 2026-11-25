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
    public var isSyncArchive: Bool { name.hasPrefix(WebDAVSync.backupPrefix) && name.lowercased().hasSuffix(".zip") }
}

public enum WebDAVSyncDirection: Equatable, Sendable {
    case upload, download, unchanged, conflict
}

public enum WebDAVSyncError: LocalizedError, Equatable {
    case invalidDirectory, invalidBackupName, unexpectedResponse
    case httpStatus(method: String, path: String, code: Int)

    public var statusCode: Int? {
        if case .httpStatus(_, _, let code) = self { return code }
        return nil
    }

    public var errorDescription: String? {
        switch self {
        case .invalidDirectory: "请输入有效的 WebDAV 服务器或 HTTP(S) 目录地址。"
        case .invalidBackupName: "请输入当前备份目录中的 ZIP 文件名。"
        case .unexpectedResponse: "无法读取 WebDAV 服务器的响应。"
        case let .httpStatus(method, path, code): "WebDAV \(method) \(path) 返回 HTTP \(code)。"
        }
    }
}

public final class WebDAVSync: Sendable {
    public let fileURL: URL
    private let directoryURL: URL
    private let authorization: String?
    private let session: URLSession
    private let makeTaskDelegate: @Sendable () -> WebDAVTaskDelegate

    public convenience init(directoryURL: String, username: String, password: String) throws {
        try self.init(directoryURL: directoryURL, username: username, password: password,
                      configuration: .ephemeral)
    }

    init(directoryURL: String, username: String, password: String, configuration: URLSessionConfiguration) throws {
        let address = try WebDAVAddress.complete(directoryURL)
        guard var parts = URLComponents(url: address, resolvingAgainstBaseURL: false) else {
            throw WebDAVSyncError.invalidDirectory
        }
        let login = username.isEmpty ? parts.user ?? "" : username
        let secret = username.isEmpty && password.isEmpty ? parts.password ?? "" : password
        parts.user = nil
        parts.password = nil
        guard let directory = parts.url else { throw WebDAVSyncError.invalidDirectory }
        self.directoryURL = directory
        fileURL = directory.appendingPathComponent("legado-sync.json", isDirectory: false)
        authorization = login.isEmpty && secret.isEmpty ? nil : "Basic " + Data("\(login):\(secret)".utf8).base64EncodedString()
        configuration.urlCredentialStorage = nil
        makeTaskDelegate = { WebDAVTaskDelegate(directory: directory, username: login, password: secret) }
        session = URLSession(configuration: configuration)
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
        let get = request(method: "GET")
        let (data, response) = try await send(get)
        if response.statusCode == 404 { return nil }
        try Self.check(response, request: get)
        return WebDAVRemoteSnapshot(data: data, etag: response.value(forHTTPHeaderField: "ETag"))
    }

    public func upload(_ data: Data, replacing _: WebDAVRemoteSnapshot?) async throws {
        var put = request(method: "PUT")
        put.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        put.httpBody = data
        try await upload(put) { try await send(put).1 }
    }

    public func checkConnection() async throws {
        try await checkCollection(directoryURL)
    }

    public func allowedMethods() async throws -> [String] {
        let options = request(method: "OPTIONS", url: directoryURL)
        let (body, response) = try await send(options)
        try Self.check(response, request: options)
        if response.statusCode == 207 { _ = try WebDAVListing.parse(body, request: options) }
        let allow = response.value(forHTTPHeaderField: "Allow") ?? ""
        var seen = Set<String>()
        return allow.split(separator: ",").compactMap {
            let method = $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            return !method.isEmpty && seen.insert(method).inserted ? method : nil
        }
    }

    public func createBackupDirectory() async throws {
        _ = try await createCollection(directoryURL, verifyExisting: true)
    }

    private func checkCollection(_ directory: URL) async throws {
        let query = propfind(directory, depth: 0, properties: "<D:resourcetype/>")
        let (xml, response) = try await send(query)
        try Self.check(response, request: query)
        let entries = try WebDAVListing.parse(xml, request: query)
        guard entries.count == 1, let entry = entries.first else { throw WebDAVSyncError.unexpectedResponse }
        guard entry.properties["collection"] != nil else {
            if let code = entry.resourceTypeFailure {
                throw WebDAVSyncError.httpStatus(method: "PROPFIND", path: directory.path, code: code)
            }
            throw WebDAVSyncError.unexpectedResponse
        }
    }

    private func propfind(_ directory: URL, depth: Int, properties: String) -> URLRequest {
        var query = request(method: "PROPFIND", url: directory)
        query.setValue(String(depth), forHTTPHeaderField: "Depth")
        query.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        query.httpBody = Data("<D:propfind xmlns:D=\"DAV:\"><D:prop>\(properties)</D:prop></D:propfind>".utf8)
        return query
    }

    public func listBackups(includeOtherArchives: Bool = false) async throws -> [WebDAVBackupFile] {
        let properties = "<D:resourcetype/><D:getlastmodified/><D:getcontentlength/><D:creationdate/>"
        let query = propfind(directoryURL, depth: 1, properties: properties)
        let (xml, response) = try await send(query)
        if [404, 409].contains(response.statusCode) { return [] }
        try Self.check(response, request: query)
        let entries: [WebDAVListing.Entry]
        do { entries = try WebDAVListing.parse(xml, request: query, listingChildren: true) }
        catch let error as WebDAVSyncError where error.statusCode == 404 || error.statusCode == 409 { return [] }

        // A DAV proxy can return an internal mount path. Use the collection named in
        // this listing to interpret its children, but always GET from the user's URL.
        let canonicalDirectory = Self.collectionURL(in: entries, relativeTo: directoryURL)
        var files: [String: WebDAVBackupFile] = [:]
        let httpDate = Self.dateFormatter("EEE, dd MMM yyyy HH:mm:ss zzz")
        let timestamp = Self.dateFormatter(Self.timestampFormat)
        let isoDate = ISO8601DateFormatter()
        let fractionalDate = ISO8601DateFormatter()
        fractionalDate.formatOptions.insert(.withFractionalSeconds)
        for entry in entries {
            guard entry.properties["collection"] == nil,
                  let name = Self.backupName(href: entry.href, relativeTo: directoryURL)
                    ?? canonicalDirectory.flatMap({ Self.backupName(href: entry.href, relativeTo: $0) }) else { continue }
            let modified = entry.properties["getlastmodified"].flatMap(httpDate.date(from:))
            let stamp = name.dropFirst(Self.backupPrefix.count).prefix(19)
            let created = name.hasPrefix(Self.backupPrefix) && stamp.count == 19 ? timestamp.date(from: String(stamp)) : nil
            let creationDate = entry.properties["creationdate"].flatMap { isoDate.date(from: $0) ?? fractionalDate.date(from: $0) }
            let date = created ?? modified ?? creationDate ?? .distantPast
            let file = WebDAVBackupFile(name: name, date: date, size: entry.properties["getcontentlength"].flatMap(Int64.init))
            if includeOtherArchives || file.isLegacySnapshot || file.isSyncArchive { files[name] = file }
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
        var put = request(method: "PUT", url: directoryURL.appendingPathComponent(name))
        put.setValue("application/zip", forHTTPHeaderField: "Content-Type")
        try await upload(put) {
            try await perform { connection, delegate in
                try await connection.upload(for: put, fromFile: file, delegate: delegate)
            }.1
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        return WebDAVBackupFile(name: name, date: date, size: (attributes?[.size] as? NSNumber)?.int64Value)
    }

    public func downloadBackup(_ backup: WebDAVBackupFile, to file: URL) async throws {
        let get = try request(method: "GET", url: backupURL(named: backup.name))
        let (download, response) = try await perform { connection, delegate in
            try await connection.download(for: get, delegate: delegate)
        }
        defer { try? FileManager.default.removeItem(at: download) }
        try Self.check(response, request: get)
        try FileManager.default.moveItem(at: download, to: file)
    }

    public func backupSize(_ backup: WebDAVBackupFile) async throws -> Int64? {
        let head = try request(method: "HEAD", url: backupURL(named: backup.name))
        let (_, response) = try await send(head)
        try Self.check(response, request: head)
        guard let length = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init),
              length >= 0 else { return nil }
        return length
    }

    public func copyBackup(_ backup: WebDAVBackupFile, to name: String) async throws {
        try await changeBackup(backup, method: "COPY", destination: name)
    }

    public func moveBackup(_ backup: WebDAVBackupFile, to name: String) async throws {
        try await changeBackup(backup, method: "MOVE", destination: name)
    }

    public func deleteBackup(_ backup: WebDAVBackupFile) async throws {
        try await changeBackup(backup, method: "DELETE")
    }

    private func changeBackup(_ backup: WebDAVBackupFile, method: String, destination: String? = nil) async throws {
        guard !backup.isLegacySnapshot else { throw WebDAVSyncError.invalidBackupName }
        var change = try request(method: method, url: backupURL(named: backup.name))
        if let destination {
            guard destination.lowercased().hasSuffix(".zip") else { throw WebDAVSyncError.invalidBackupName }
            let target = try backupURL(named: destination)
            change.setValue(target.absoluteString, forHTTPHeaderField: "Destination")
            change.setValue("F", forHTTPHeaderField: "Overwrite")
        }
        let (xml, response) = try await send(change)
        try Self.check(response, request: change)
        if response.statusCode == 207 { _ = try WebDAVListing.parse(xml, request: change) }
    }

    private func backupURL(named name: String) throws -> URL {
        guard Self.isPathComponent(name), Self.isBackupName(name) else { throw WebDAVSyncError.invalidBackupName }
        return directoryURL.appendingPathComponent(name, isDirectory: false)
    }

    fileprivate static let backupPrefix = "legado-ios-"
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
    fileprivate static func encodedAddress(_ address: String) -> String? {
        address.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed.union(CharacterSet(charactersIn: "%#[]")))
    }

    private static func isPathComponent(_ component: String) -> Bool {
        !component.isEmpty && component != "." && component != ".." &&
            !component.contains("/") && !component.contains("\\") &&
            component.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private static func collectionURL(in entries: [WebDAVListing.Entry], relativeTo directory: URL) -> URL? {
        let collections = entries.compactMap { entry -> URL? in
            guard entry.properties["collection"] != nil, let href = encodedAddress(entry.href),
                  let url = URL(string: href, relativeTo: directory)?.absoluteURL else { return nil }
            return url.hasDirectoryPath ? url : url.appendingPathComponent("", isDirectory: true)
        }
        // Depth 1 contains only the requested collection and its immediate children.
        // If an entry names our directory, no alias is needed. Otherwise only use an
        // alias that accounts for every reported collection.
        if collections.contains(directory) { return nil }
        return collections.first { root in
            root.deletingLastPathComponent() != directory &&
                collections.allSatisfy { $0 == root || $0.deletingLastPathComponent() == root }
        }
    }

    private static func isBackupName(_ name: String) -> Bool {
        name == "legado-sync.json" || name.lowercased().hasSuffix(".zip")
    }

    private static func backupName(href: String, relativeTo directoryURL: URL) -> String? {
        guard let address = Self.encodedAddress(href),
              let url = URL(string: address, relativeTo: directoryURL)?.absoluteURL,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let directory = URLComponents(url: directoryURL, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == directory.scheme?.lowercased(),
              parts.host?.lowercased() == directory.host?.lowercased(),
              (parts.port ?? (parts.scheme?.lowercased() == "https" ? 443 : 80))
                == (directory.port ?? (directory.scheme?.lowercased() == "https" ? 443 : 80)),
              parts.user == nil, parts.password == nil, !parts.percentEncodedPath.hasSuffix("/") else { return nil }
        let components = parts.percentEncodedPath.split(separator: "/").map { String($0).removingPercentEncoding }
        let parent = directory.percentEncodedPath.split(separator: "/").map { String($0).removingPercentEncoding }
        guard components.dropLast().elementsEqual(parent), let name = components.last ?? nil,
              Self.isPathComponent(name), Self.isBackupName(name) else { return nil }
        return name
    }

    private func upload(_ request: URLRequest, sending: () async throws -> HTTPURLResponse) async throws {
        var response = try await sending()
        if [404, 409].contains(response.statusCode), directoryURL.path != "/" {
            let denied = try await createCollection(directoryURL)
            response = try await sending()
            if [404, 409].contains(response.statusCode), let denied { throw denied }
        }
        try Self.check(response, request: request)
    }

    private func createCollection(_ directory: URL, verifyExisting: Bool = false) async throws -> WebDAVSyncError? {
        let mkcol = request(method: "MKCOL", url: directory)
        var (body, response) = try await send(mkcol)
        if [404, 409].contains(response.statusCode) {
            let parent = directory.deletingLastPathComponent()
            if !parent.path.isEmpty, parent.path != "/" {
                let denied = try await createCollection(parent, verifyExisting: verifyExisting)
                (body, response) = try await send(mkcol)
                if [404, 409].contains(response.statusCode), let denied { throw denied }
            }
        }
        if verifyExisting, [403, 405].contains(response.statusCode) {
            do { try await checkCollection(directory) }
            catch is WebDAVSyncError { try Self.check(response, request: mkcol) }
            return nil
        }
        if verifyExisting, (200..<300).contains(response.statusCode), response.statusCode != 201 {
            if response.statusCode == 207 { _ = try WebDAVListing.parse(body, request: mkcol) }
            try await checkCollection(directory)
            return nil
        }
        // Servers return 405 or 403 when a collection already exists. Retry the
        // requested write in that directory to let the server decide if it can proceed.
        switch response.statusCode {
        case 403: return .httpStatus(method: "MKCOL", path: directory.path, code: 403)
        case 405: return nil
        default: try Self.check(response, request: mkcol); return nil
        }
    }

    private func request(method: String, url: URL? = nil) -> URLRequest {
        var request = URLRequest(url: url ?? fileURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = method
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await perform { connection, delegate in
            try await connection.data(for: request, delegate: delegate)
        }
    }

    private func perform<T>(_ operation: (URLSession, WebDAVTaskDelegate) async throws -> (T, URLResponse))
        async throws -> (T, HTTPURLResponse) {
        let delegate = makeTaskDelegate()
        #if canImport(FoundationNetworking)
        // Corelibs delivers authentication challenges only to the session delegate.
        let connection = URLSession(configuration: session.configuration, delegate: delegate, delegateQueue: nil)
        defer { connection.finishTasksAndInvalidate() }
        #else
        let connection = session
        #endif
        do {
            let (data, response) = try await operation(connection, delegate)
            guard let http = response as? HTTPURLResponse else { throw WebDAVSyncError.unexpectedResponse }
            return (data, http)
        } catch {
            if !Task.isCancelled, let failure = delegate.authenticationFailure { throw failure }
            throw error
        }
    }

    private static func check(_ response: HTTPURLResponse, request: URLRequest) throws {
        guard (200..<300).contains(response.statusCode) else {
            throw WebDAVSyncError.httpStatus(method: request.httpMethod ?? "GET",
                                             path: response.url?.path ?? request.url?.path ?? "/",
                                             code: response.statusCode)
        }
    }
}

private final class WebDAVTaskDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let directory: URL
    private let username: String
    private let password: String
    private let lock = NSLock()
    private var failure: WebDAVSyncError?
    var authenticationFailure: WebDAVSyncError? { lock.withLock { failure } }

    init(directory: URL, username: String, password: String) {
        self.directory = directory
        self.username = username
        self.password = password
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest:
            let space = challenge.protectionSpace
            let scheme = directory.scheme?.lowercased()
            guard !username.isEmpty, challenge.previousFailureCount == 0, space.proxyType == nil,
                  space.host.lowercased() == directory.host?.lowercased(), space.protocol?.lowercased() == scheme,
                  space.port == (directory.port ?? (scheme == "https" ? 443 : 80)) else {
                // URLSession can surface a rejected challenge as cancellation instead of its HTTP response.
                if let response = (challenge.failureResponse ?? task.response) as? HTTPURLResponse,
                   [401, 407].contains(response.statusCode),
                   let method = task.currentRequest?.httpMethod, let path = response.url?.path {
                    lock.withLock { failure = .httpStatus(method: method, path: path, code: response.statusCode) }
                }
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(user: username, password: password, persistence: .none))
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let target = request.url, let original = task.originalRequest,
              let scheme = target.scheme?.lowercased(), ["http", "https"].contains(scheme),
              target.user == nil, target.password == nil else {
            completionHandler(nil)
            return
        }
        let sameOrigin = scheme == directory.scheme?.lowercased() &&
            target.host?.lowercased() == directory.host?.lowercased() &&
            (target.port ?? (scheme == "https" ? 443 : 80)) == (directory.port ?? (scheme == "https" ? 443 : 80))
        if sameOrigin, request.httpMethod == original.httpMethod {
            completionHandler(request)
        } else if original.httpMethod == "GET", request.httpMethod == "GET" {
            // A DAV server can redirect the selected download to a CDN's signed URL.
            // A fresh request carries no DAV credentials or cookies to that host.
            var download = URLRequest(url: target)
            download.httpShouldHandleCookies = false
            completionHandler(download)
        } else {
            completionHandler(nil)
        }
    }
}

/// Parse only direct DAV properties with a successful propstat. A multistatus may report
/// missing properties with a separate 404 for the same resource.
private final class WebDAVListing: NSObject, XMLParserDelegate {
    struct Entry {
        var href = ""
        var properties: [String: String] = [:]
        var resourceTypeFailure: Int?
        var hasStatus = false
    }

    private var entries: [Entry] = []
    private var path: [String] = []
    private var text = ""
    private var entry = Entry()
    private var responseStatus: Int?
    private var failures: [(href: String, code: Int)] = []
    private var properties: [String: String] = [:]
    private var propertyStatus: Int?
    private var firstPropertyFailure: Int?
    private var foundMultistatus = false

    static func parse(_ data: Data, request: URLRequest, listingChildren: Bool = false) throws -> [Entry] {
        guard let url = request.url, let method = request.httpMethod else { throw WebDAVSyncError.unexpectedResponse }
        let delegate = WebDAVListing()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.foundMultistatus else { throw WebDAVSyncError.unexpectedResponse }
        if !listingChildren {
            let propertyError = method == "PROPFIND" ? nil : delegate.firstPropertyFailure
            if let code = delegate.failures.first?.code ?? propertyError {
                throw WebDAVSyncError.httpStatus(method: method, path: url.path, code: code)
            }
            guard !delegate.entries.isEmpty, delegate.entries.allSatisfy(\.hasStatus) else {
                throw WebDAVSyncError.unexpectedResponse
            }
        } else if delegate.entries.isEmpty, let failure = delegate.failures.first(where: {
            guard let href = WebDAVSync.encodedAddress($0.href),
                  let target = URL(string: href, relativeTo: url)?.absoluteURL else { return false }
            return target.host?.lowercased() == url.host?.lowercased() && target.path == url.path
        }) {
            throw WebDAVSyncError.httpStatus(method: method, path: url.path, code: failure.code)
        }
        return delegate.entries
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        path.append(namespaceURI == "DAV:" ? elementName : "")
        text = ""
        switch path {
        case ["multistatus"]:
            foundMultistatus = true
        case ["multistatus", "response"]:
            entry = Entry()
            responseStatus = nil
        case ["multistatus", "response", "propstat"]:
            properties.removeAll(keepingCapacity: true)
            propertyStatus = nil
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
            responseStatus = readStatus(value)
            entry.hasStatus = true
        case ["multistatus", "response", "propstat", "status"]:
            propertyStatus = readStatus(value)
        case ["multistatus", "response", "propstat"]:
            if let propertyStatus {
                entry.hasStatus = true
                if (200..<300).contains(propertyStatus) {
                    entry.properties.merge(properties) { _, new in new }
                } else {
                    if firstPropertyFailure == nil { firstPropertyFailure = propertyStatus }
                    if properties["resourcetype"] != nil { entry.resourceTypeFailure = propertyStatus }
                }
            }
        case ["multistatus", "response"]:
            if let status = responseStatus, !(200..<300).contains(status) {
                failures.append((entry.href, status))
            } else if !entry.href.isEmpty {
                entries.append(entry)
            }
        default:
            if path.dropLast().elementsEqual(["multistatus", "response", "propstat", "prop"]),
               let key = path.last, ["getlastmodified", "creationdate", "getcontentlength", "resourcetype"].contains(key) {
                properties[key] = value
            }
        }
        path.removeLast()
        text = ""
    }

    private func readStatus(_ status: String) -> Int {
        let fields = status.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2, let code = Int(fields[1]) else { return 0 }
        return code
    }
}
