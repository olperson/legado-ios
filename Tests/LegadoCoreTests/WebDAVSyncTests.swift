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
        #expect(WebDAVSync.fingerprint(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func completesDirectoryAddressesWithoutChangingSelectedPaths() throws {
        let addresses = [
            ("  dav.example.test  ", "https://dav.example.test/"),
            ("http://localhost:8081", "http://localhost:8081/"),
            ("localhost:8443/prefix", "https://localhost:8443/prefix/"),
            ("[::1]:8443/书架/My%20Books", "https://[::1]:8443/%E4%B9%A6%E6%9E%B6/My%20Books/"),
            ("dav.jianguoyun.com", "https://dav.jianguoyun.com/dav/"),
            ("dav.jianguoyun.com/", "https://dav.jianguoyun.com/"),
            ("dav.jianguoyun.com/archive", "https://dav.jianguoyun.com/archive/"),
            ("dav.test/My%20Books/[25%]?item[]=a%2Fb", "https://dav.test/My%20Books/%5B25%25%5D/?item%5B%5D=a%2Fb"),
            ("https://dav.example.test/p%2Fq?token=a%2Bb#bookmark", "https://dav.example.test/p%2Fq/?token=a%2Bb")
        ]
        for (input, expected) in addresses {
            let directory = try WebDAVAddress.complete(input)
            #expect(directory.absoluteString == expected)
            #expect(try WebDAVAddress.complete(directory.absoluteString) == directory)
            let client = try WebDAVSync(directoryURL: input, username: "", password: "")
            #expect(client.fileURL == directory.appendingPathComponent("legado-sync.json"))
        }
        for input in ["", "http://", "/directory", "not a host", "ftp://dav.test/a", "mailto:user@example.test"] {
            #expect(throws: WebDAVSyncError.invalidDirectory) { try WebDAVAddress.complete(input) }
        }
    }

    @Test func appliesServicePresetsWithoutDuplicatingRoutesOrExposingCredentials() throws {
        let nextcloud = WebDAVAddress.Preset.nextcloud
        let base = "http://user:secret@localhost:8080/Cloud%20Drive"
        let endpoint = "http://localhost:8080/Cloud%20Drive/remote.php/dav/files/%E8%AF%BB%E8%80%85%20%2F%23/"
        #expect(try nextcloud.directory(for: base, username: "读者 /#") == endpoint)
        #expect(try nextcloud.directory(for: endpoint, username: "读者 /#") == endpoint)
        #expect(try nextcloud.directory(for: endpoint + "books/", username: "new") ==
                "http://localhost:8080/Cloud%20Drive/remote.php/dav/files/new/books/")
        #expect(throws: (any Error).self) { try nextcloud.directory(for: base, username: "") }
        let alist = WebDAVAddress.Preset.alist
        #expect(try alist.directory(for: base, username: "") == "http://localhost:8080/Cloud%20Drive/dav/")
        #expect(try alist.directory(for: "dav.test/p/dav/books", username: "") == "https://dav.test/p/dav/books/")
        #expect(try WebDAVAddress.Preset.nutstore.directory(for: base + "?token=secret", username: "user") ==
                "https://dav.jianguoyun.com/dav/legado/")
    }

    @Test func acceptsEmbeddedAuthenticationWithoutIncludingItInRequestURLs() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebDAVFixtureProtocol.self]
        let client = try WebDAVSync(directoryURL: "https://reader:t%65st@dav.test/existing?token=a%2Bb",
                                    username: "", password: "", configuration: configuration)
        #expect(client.fileURL.absoluteString == "https://dav.test/existing/legado-sync.json?token=a%2Bb")
        #expect(try await client.fetch()?.data == Data("{}".utf8))
    }

    @Test func readsAndWritesLegacySnapshotsWithoutConditionalHeaders() async throws {
        let existing = try makeClient("existing")
        let snapshot = try #require(try await existing.fetch())
        #expect(snapshot.data == Data("{}".utf8))
        try await existing.upload(remote, replacing: snapshot)

        let empty = try makeClient("missing")
        #expect(try await empty.fetch() == nil)
        try await empty.upload(local, replacing: nil)
    }

    @Test func reportsTheActualFailedRequest() async throws {
        for (route, code) in [("unauthorized", 401), ("forbidden", 403), ("server-error", 503)] {
            let client = try makeClient(route)
            await #expect(throws: WebDAVSyncError.httpStatus(method: "GET", path: "/\(route)/legado-sync.json", code: code)) {
                _ = try await client.fetch()
            }
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
        guard let url = request.url, url.lastPathComponent == "legado-sync.json",
              request.value(forHTTPHeaderField: "Authorization") == "Basic cmVhZGVyOnRlc3Q=" else {
            reply(401)
            return
        }
        let route = url.deletingLastPathComponent().lastPathComponent
        switch (route, request.httpMethod) {
        case ("existing", "GET"): reply(200, body: "{}")
        case ("missing", "GET"): reply(404)
        case ("existing", "PUT"), ("missing", "PUT"):
            let hasCondition = ["If-Match", "If-None-Match"].contains { request.value(forHTTPHeaderField: $0) != nil }
            reply(hasCondition ? 403 : 201)
        case ("unauthorized", _): reply(401)
        case ("forbidden", _): reply(403)
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
