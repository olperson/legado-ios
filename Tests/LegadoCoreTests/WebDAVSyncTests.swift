import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import LegadoCore

struct WebDAVSyncTests {
    private let local = Data(#"{"version":1,"books":[]}"#.utf8)
    private let remote = Data(#"{"version":1,"books":["a"]}"#.utf8)

    @Test func decidesDirectionAgainstLastSuccessfulSnapshot() {
        func direction(_ base: Data?, _ remoteFile: Data?, empty: Bool = false, remoteEmpty: Bool = false) -> WebDAVSyncDirection {
            WebDAVSync.direction(local: local, localIsEmpty: empty, remoteData: remoteFile,
                                 remoteIsEmpty: remoteEmpty, base: base.map(WebDAVSync.fingerprint))
        }
        #expect(direction(nil, nil) == .upload)
        #expect(direction(nil, local) == .unchanged)
        #expect(direction(nil, remote) == .conflict)
        #expect(direction(nil, remote, empty: true) == .download)
        #expect(direction(nil, remote, remoteEmpty: true) == .upload)
        #expect(direction(local, remote) == .download)
        #expect(direction(remote, remote) == .upload)
        #expect(direction(Data([3]), remote) == .conflict)
        #expect(direction(Data([3]), local) == .unchanged)
        #expect(direction(local, nil) == .conflict)
    }

    @Test func addressesUseTheConfiguredDirectory() throws {
        let client = try WebDAVSync(directoryURL: " https://example.test/dav/My%20Library/ ", username: "", password: "")
        #expect(client.fileURL.absoluteString == "https://example.test/dav/My%20Library/legado-sync.json")
        for input in ["", "dav.example", "ftp://dav.example", "https://me@dav.example", "https://dav.example?token=abc"] {
            #expect(throws: WebDAVSyncError.invalidDirectory) {
                _ = try WebDAVSync(directoryURL: input, username: "", password: "")
            }
        }
        #expect(throws: WebDAVSyncError.invalidUsername) {
            _ = try WebDAVSync(directoryURL: "https://example.test", username: "invalid:name", password: "test")
        }
        #expect(WebDAVSync.fingerprint(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func readsAndWritesWithConditionalRequests() async throws {
        let existing = try makeClient("existing")
        let snapshot = try #require(try await existing.fetch())
        #expect(snapshot.data == Data("{}".utf8))
        #expect(snapshot.etag == "\"current\"")
        try await existing.verifyUnchanged(snapshot)
        try await existing.upload(remote, replacing: snapshot)

        let empty = try makeClient("missing")
        #expect(try await empty.fetch() == nil)
        try await empty.upload(local, replacing: nil)
    }

    @Test func reportsAuthenticationRedirectsAndUnexpectedContent() async throws {
        for (route, error): (String, WebDAVSyncError) in [
            ("unauthorized", .unauthorized), ("forbidden", .forbidden), ("redirect", .redirected),
            ("login", .unexpectedResponse), ("server-error", .httpStatus(503))
        ] {
            let client = try makeClient(route)
            await #expect(throws: error) { _ = try await client.fetch() }
        }
        let login = try makeClient("login")
        await #expect(throws: WebDAVSyncError.unexpectedResponse) { try await login.upload(local, replacing: nil) }
        let missingDirectory = try makeClient("no-directory")
        await #expect(throws: WebDAVSyncError.missingDirectory) { try await missingDirectory.upload(local, replacing: nil) }
    }

    @Test func detectsConcurrentCreationEditingAndWeakETags() async throws {
        let raced = try makeClient("raced")
        await #expect(throws: WebDAVSyncError.remoteChanged) { try await raced.upload(local, replacing: nil) }
        let existing = try makeClient("existing")
        let stale = WebDAVRemoteSnapshot(data: remote, etag: "\"old\"")
        await #expect(throws: WebDAVSyncError.remoteChanged) { try await existing.verifyUnchanged(stale) }
        await #expect(throws: WebDAVSyncError.remoteChanged) { try await existing.verifyUnchanged(nil) }
        await #expect(throws: WebDAVSyncError.remoteChanged) { try await existing.upload(local, replacing: stale) }
        for tag in [nil, "W/\"weak\"", "*", "unquoted", "\"one\", \"two\""] as [String?] {
            let unprotected = WebDAVRemoteSnapshot(data: remote, etag: tag)
            await #expect(throws: WebDAVSyncError.missingStrongETag) { try await existing.upload(local, replacing: unprotected) }
        }
    }

    private func makeClient(_ route: String) throws -> WebDAVSync {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebDAVFixtureProtocol.self]
        return try WebDAVSync(directoryURL: "https://dav.test/\(route)", username: "reader", password: "test",
                              configuration: configuration)
    }
}

private final class WebDAVFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        if request.httpMethod == "MKCOL", request.url?.lastPathComponent == "no-directory" {
            reply(405)
            return
        }
        guard let url = request.url, url.lastPathComponent == "legado-sync.json",
              request.value(forHTTPHeaderField: "Authorization") == "Basic cmVhZGVyOnRlc3Q=" else {
            reply(401)
            return
        }
        let route = url.deletingLastPathComponent().lastPathComponent
        switch (route, request.httpMethod) {
        case ("existing", "GET"): reply(200, headers: ["ETag": "\"current\""], body: "{}")
        case ("existing", "PUT"): reply(request.value(forHTTPHeaderField: "If-Match") == "\"current\"" ? 204 : 412)
        case ("missing", "GET"): reply(404)
        case ("missing", "PUT"): reply(request.value(forHTTPHeaderField: "If-None-Match") == "*" ? 201 : 428)
        case ("no-directory", "PUT"): reply(409)
        case ("raced", "PUT"): reply(412)
        case ("unauthorized", _): reply(401)
        case ("forbidden", _): reply(403)
        case ("redirect", _): reply(302)
        case ("login", _): reply(200, headers: ["Content-Type": "text/html"], body: "<html>Login</html>")
        default: reply(503)
        }
    }

    private func reply(_ status: Int, headers: [String: String] = [:], body: String = "") {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
