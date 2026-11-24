import CryptoKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct WebDAVRemoteSnapshot: Equatable, Sendable {
    public let data: Data
    public let etag: String?
}

public enum WebDAVSyncDirection: Equatable, Sendable {
    case upload, download, unchanged, conflict
}

public enum WebDAVSyncError: LocalizedError, Equatable {
    case invalidDirectory, invalidUsername, unauthorized, forbidden, missingDirectory
    case redirected, remoteChanged, missingStrongETag, unexpectedResponse
    case httpStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidDirectory: "请输入 WebDAV 目录的完整 HTTP 或 HTTPS 地址。"
        case .invalidUsername: "请检查 WebDAV 用户名。"
        case .unauthorized: "WebDAV 身份验证失败，请检查用户名和密码。"
        case .forbidden: "WebDAV 拒绝访问，请检查目录权限。"
        case .missingDirectory: "找不到 WebDAV 目录，请先创建目录并检查地址。"
        case .redirected: "服务器返回了重定向，请填写最终的 WebDAV 目录地址。"
        case .remoteChanged: "云端文件已发生变化，请重新同步。"
        case .missingStrongETag: "服务器未提供可用于安全覆盖的强 ETag。请稍后重试，也可以从云端下载。"
        case .unexpectedResponse: "服务器返回了意外内容，请检查 WebDAV 目录地址。"
        case .httpStatus(let code): "WebDAV 请求失败（HTTP \(code)）。"
        }
    }
}

public final class WebDAVSync: Sendable {
    public let fileURL: URL
    private let authorization: String?
    private let session: URLSession

    public convenience init(directoryURL: String, username: String, password: String) throws {
        try self.init(directoryURL: directoryURL, username: username, password: password,
                      configuration: .ephemeral)
    }

    init(directoryURL: String, username: String, password: String, configuration: URLSessionConfiguration) throws {
        guard let parts = URLComponents(string: directoryURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, let directory = parts.url else {
            throw WebDAVSyncError.invalidDirectory
        }
        guard !username.contains(":"), !username.isEmpty || password.isEmpty else {
            throw WebDAVSyncError.invalidUsername
        }
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
        let (body, response) = try await send(put)
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

    private func request(method: String) -> URLRequest {
        var request = URLRequest(url: fileURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = method
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json, */*;q=0.5", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw WebDAVSyncError.unexpectedResponse }
            return (data, http)
        } catch let error as URLError where !Task.isCancelled &&
            [.userAuthenticationRequired, .userCancelledAuthentication, .cancelled].contains(error.code) {
            // Rejecting a repeated credential challenge can cancel the request
            // instead of delivering the server's 401 as an HTTP response.
            throw WebDAVSyncError.unauthorized
        }
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
        case 300..<400: .redirected
        case 401: .unauthorized
        case 403: .forbidden
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
