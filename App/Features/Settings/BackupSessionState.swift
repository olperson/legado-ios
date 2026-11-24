import Foundation
@preconcurrency import WebKit

struct BackupSessionState {
    private struct Contents: Codable {
        var version = 1
        var account: WebDAVAccount?
        var http: [SavedCookie] = []
        var web: [SavedCookie] = []
        var sources: [String: [SourceNetworkPolicy.StoredCookie]] = [:]
    }

    private let account: WebDAVAccount?
    private let httpCookies: [HTTPCookie]
    private let webCookies: [HTTPCookie]
    private let sourceCookies: [String: [SourceNetworkPolicy.StoredCookie]]

    @MainActor static func capture() async throws -> Data {
        let web = await storedCookies(in: WKWebsiteDataStore.default().httpCookieStore)
        func sorted(_ cookies: [HTTPCookie]) -> [SavedCookie] {
            cookies.map(SavedCookie.init).sorted {
                ($0.domain, $0.path, $0.name) < ($1.domain, $1.path, $1.name)
            }
        }
        let contents = Contents(account: try WebDAVAccount.load(),
                                http: sorted(HTTPCookieStorage.shared.cookies ?? []), web: sorted(web),
                                sources: await SourceNetworkPolicy.shared.cookiesForBackup())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(contents)
    }

    static func decode(_ data: Data?) throws -> Self {
        let saved = try data.map { try JSONDecoder().decode(Contents.self, from: $0) } ?? Contents()
        guard saved.version == 1 else { throw BackupSessionError.invalidContents }
        if let account = saved.account { _ = try account.makeClient() }
        for jar in saved.sources.values {
            for cookie in jar where !valid(name: cookie.name, value: cookie.value, domain: cookie.domain, path: cookie.path) {
                throw BackupSessionError.invalidContents
            }
        }
        return try Self(account: saved.account,
                        httpCookies: saved.http.map { try $0.cookie() },
                        webCookies: saved.web.map { try $0.cookie() },
                        sourceCookies: saved.sources)
    }

    func applyAccount() throws {
        if let account { try account.save() } else { try WebDAVAccount.remove() }
    }

    @MainActor func applyCookies() async {
        BookSourceRuntimeStore.shared.invalidateAfterDatabaseRestore()
        await SourceNetworkPolicy.shared.restoreCookies(sourceCookies)
        let storage = HTTPCookieStorage.shared
        let web = WKWebsiteDataStore.default().httpCookieStore
        // Clear both jars before filling either of them: WebKit can synchronize
        // cookie deletions with the shared URLSession cookie store.
        for cookie in await Self.storedCookies(in: web) { await web.deleteCookie(cookie) }
        for cookie in storage.cookies ?? [] { storage.deleteCookie(cookie) }
        let now = Date()
        for cookie in webCookies where cookie.expiresDate.map({ $0 > now }) ?? true { await web.setCookie(cookie) }
        for cookie in httpCookies where cookie.expiresDate.map({ $0 > now }) ?? true { storage.setCookie(cookie) }
    }

    @MainActor private static func storedCookies(in store: WKHTTPCookieStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.getAllCookies { continuation.resume(returning: $0) }
        }
    }

    private static func valid(name: String, value: String, domain: String, path: String) -> Bool {
        !name.isEmpty && !domain.isEmpty && path.hasPrefix("/") &&
            [name, value, domain, path].allSatisfy { !$0.contains(where: { $0.isNewline || $0 == "\0" }) }
    }

    private struct SavedCookie: Codable {
        let name: String
        let value: String
        let domain: String
        let path: String
        let secure: Bool
        let httpOnly: Bool
        let sessionOnly: Bool
        let expires: Date?
        let version: Int
        let sameSite: String?
        let ports: [Int]?
        let comment: String?
        let commentURL: String?
        let setByJavaScript: String?

        init(_ cookie: HTTPCookie) {
            name = cookie.name
            value = cookie.value
            domain = cookie.domain
            path = cookie.path
            secure = cookie.isSecure
            httpOnly = cookie.isHTTPOnly
            sessionOnly = cookie.isSessionOnly
            expires = cookie.expiresDate
            version = cookie.version
            sameSite = cookie.sameSitePolicy?.rawValue
            ports = cookie.portList?.map(\.intValue)
            comment = cookie.comment
            commentURL = cookie.commentURL?.absoluteString
            if #available(iOS 18.2, *) {
                setByJavaScript = cookie.properties?[.setByJavaScript].map { String(describing: $0) }
            } else {
                setByJavaScript = nil
            }
        }

        func cookie() throws -> HTTPCookie {
            guard BackupSessionState.valid(name: name, value: value, domain: domain, path: path),
                  (0...1).contains(version), ports?.allSatisfy({ (0...65535).contains($0) }) != false else {
                throw BackupSessionError.invalidContents
            }
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name, .value: value, .domain: domain, .path: path,
                .version: String(version), .discard: sessionOnly ? "TRUE" : "FALSE"
            ]
            if secure { properties[.secure] = "TRUE" }
            if httpOnly { properties[HTTPCookiePropertyKey(rawValue: "HttpOnly")] = "TRUE" }
            if let expires {
                if version == 0 {
                    properties[.expires] = expires
                } else {
                    // Version 1 uses relative Max-Age. Preserve the original deadline.
                    let seconds = expires.timeIntervalSinceNow
                    guard seconds.isFinite, seconds < Double(Int.max) else { throw BackupSessionError.invalidContents }
                    properties[.maximumAge] = String(Int(max(0, seconds)))
                }
            }
            if let sameSite { properties[.sameSitePolicy] = sameSite }
            if let ports { properties[.port] = ports.map { String($0) }.joined(separator: ",") }
            if let comment { properties[.comment] = comment }
            if let commentURL { properties[.commentURL] = commentURL }
            if #available(iOS 18.2, *), let setByJavaScript { properties[.setByJavaScript] = setByJavaScript }
            guard let cookie = HTTPCookie(properties: properties), cookie.isHTTPOnly == httpOnly,
                  cookie.isSecure == secure, cookie.sameSitePolicy?.rawValue == sameSite else {
                throw BackupSessionError.invalidContents
            }
            return cookie
        }
    }
}

private enum BackupSessionError: LocalizedError {
    case invalidContents

    var errorDescription: String? { "备份中的登录状态或 Cookie 无效。" }
}
