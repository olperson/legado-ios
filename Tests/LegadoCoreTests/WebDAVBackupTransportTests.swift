import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import LegadoCore

struct WebDAVBackupTransportTests {
    @Test func preservesEscapesWhenTheDirectoryAlsoContainsUnicode() throws {
        let client = try WebDAVSync(directoryURL: "https://dav.test/My%20Library/书架", username: "", password: "")
        #expect(client.fileURL.absoluteString == "https://dav.test/My%20Library/%E4%B9%A6%E6%9E%B6/legado-sync.json")
    }

    @Test func createsMissingAncestorsAndRetriesTheOriginalOperation() async throws {
        let client = try makeClient(mode: "missing")
        #expect(try await client.listBackups().isEmpty)
        #expect(BackupDAVProtocol.methods(for: client) == ["PROPFIND"])
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: archive) }
        try BackupDAVProtocol.archive.write(to: archive)
        let uploaded = try await client.uploadBackup(from: archive)
        #expect(BackupDAVProtocol.methods(for: client) == ["PROPFIND", "PUT", "MKCOL", "MKCOL", "MKCOL", "PUT"])
        #expect(try await client.listBackups().contains { $0.name == uploaded.name })
    }

    @Test func listsOnlyFilesInTheChosenDirectoryNewestFirst() async throws {
        let client = try makeClient()
        let files = try await client.listBackups()
        #expect(files.map(\.name) == [BackupDAVProtocol.recentName, "legado-sync.json", BackupDAVProtocol.oldName])
        try #require(files.count == 3)
        #expect(files[0].size == 6)
        #expect(files[0].date > files[1].date)
        #expect(files[1].date > files[2].date)
        let manual = try await client.listBackups(includeOtherArchives: true)
        #expect(manual.map(\.name).contains("my-renamed-backup.zip"))
        #expect(manual.map(\.name).contains("no-metadata.zip"))
        #expect(manual.count == files.count + 2)
    }

    @Test func writesIndependentArchivesWithoutOverwritingHistory() async throws {
        let client = try makeClient()
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        try BackupDAVProtocol.archive.write(to: temp)
        let first = try await client.uploadBackup(from: temp)
        let second = try await client.uploadBackup(from: temp)
        #expect(first.name != second.name)
        #expect(first.name.hasSuffix(".zip") && !first.isLegacySnapshot)
        #expect(first.size == Int64(BackupDAVProtocol.archive.count))
    }

    @Test func listsCanonicalProxyHrefsAsChildrenOfTheRequestedMount() async throws {
        let client = try makeClient(mode: "proxy")
        let files = try await client.listBackups()
        #expect(files.map(\.name) == [BackupDAVProtocol.recentName, BackupDAVProtocol.oldName])
        #expect(BackupDAVProtocol.methods(for: client) == ["PROPFIND"])
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: archive) }
        try BackupDAVProtocol.archive.write(to: archive)
        let saved = try await client.uploadBackup(from: archive)
        #expect(try await client.listBackups().contains { $0.name == saved.name })
    }

    @Test func uploadsToAWriteOnlyDirectoryWithAnHTMLReceiptUsingOnePUT() async throws {
        let client = try makeClient(mode: "writeonly")
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: archive) }
        try BackupDAVProtocol.archive.write(to: archive)
        let uploaded = try await client.uploadBackup(from: archive)
        #expect(uploaded.name.hasSuffix(".zip"))
        #expect(BackupDAVProtocol.methods(for: client) == ["PUT"])
    }

    @Test func reportsTheServerStatusWhenPUTIsForbidden() async throws {
        let client = try makeClient(mode: "readonly")
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: archive) }
        try BackupDAVProtocol.archive.write(to: archive)
        do {
            _ = try await client.uploadBackup(from: archive)
            Issue.record("PUT should have returned HTTP 403.")
        } catch WebDAVSyncError.httpStatus(let method, let path, let code) {
            #expect(method == "PUT")
            #expect(code == 403)
            #expect(path.contains("/Backups/legado-ios-") && path.hasSuffix(".zip"))
        }
        #expect(BackupDAVProtocol.methods(for: client) == ["PUT"])
    }

    @Test func reportsDeniedDirectoryInsideMultiStatus() async throws {
        let client = try makeClient(mode: "denied")
        do {
            _ = try await client.listBackups()
            Issue.record("PROPFIND reported HTTP 403 for the configured directory.")
        } catch WebDAVSyncError.httpStatus(let method, _, let code) {
            #expect(method == "PROPFIND")
            #expect(code == 403)
        }
    }

    private func makeClient(mode: String = "plain") throws -> WebDAVSync {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BackupDAVProtocol.self]
        return try WebDAVSync(directoryURL: "https://\(mode)-\(UUID().uuidString).test/dav/My%20Books/Backups",
                              username: "reader", password: "test", configuration: config)
    }
}

private final class BackupDAVProtocol: URLProtocol, @unchecked Sendable {
    static let oldName = "legado-ios-20240101T130000000Z-old.zip"
    static let recentName = "legado-ios-20250101T130000000Z-new.zip"
    static let archive = Data([0x50, 0x4b, 3, 4, 25, 18])

    private final class Collections: @unchecked Sendable {
        private let lock = NSLock()
        private var created: Set<URL> = []
        private var saved: [URL: Set<String>] = [:]
        private var methodsByHost: [String: [String]] = [:]

        func record(_ request: URLRequest) {
            lock.lock()
            defer { lock.unlock() }
            methodsByHost[request.url!.host!, default: []].append(request.httpMethod!)
        }

        func methods(for host: String) -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return methodsByHost[host] ?? []
        }

        func store(_ file: URL) {
            lock.lock()
            defer { lock.unlock() }
            saved[file.deletingLastPathComponent(), default: []].insert(file.lastPathComponent)
        }

        func names(in directory: URL) -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return Array(saved[directory] ?? [])
        }

        func create(_ folder: URL) -> Int {
            lock.lock()
            defer { lock.unlock() }
            guard folder.deletingLastPathComponent().lastPathComponent == "dav" ||
                      created.contains(folder.deletingLastPathComponent()) else { return 409 }
            return created.insert(folder).inserted ? 201 : 405
        }

        func has(_ folder: URL) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return !folder.host!.hasPrefix("missing-") || created.contains(folder)
        }
    }

    private static let folders = Collections()

    static func methods(for client: WebDAVSync) -> [String] {
        folders.methods(for: client.fileURL.host!)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url,
              request.value(forHTTPHeaderField: "Authorization") == "Basic cmVhZGVyOnRlc3Q=" else {
            reply(401)
            return
        }
        Self.folders.record(request)
        if url.host!.hasPrefix("writeonly-"), request.httpMethod != "PUT" {
            reply(403)
            return
        }
        switch request.httpMethod {
        case "MKCOL":
            reply(Self.folders.create(url))
        case "PROPFIND":
            guard Self.folders.has(url) else { reply(404); return }
            guard request.value(forHTTPHeaderField: "Depth") == "1" else { reply(403); return }
            let xml = Self.listing(host: url.host!,
                                   names: Self.folders.names(in: url))
            reply(207, body: Data(xml.utf8), type: "application/xml")
        case "PUT":
            guard Self.folders.has(url.deletingLastPathComponent()) else { reply(409); return }
            if url.host!.hasPrefix("readonly-") || request.value(forHTTPHeaderField: "If-None-Match") != nil {
                reply(403)
                return
            }
            if url.pathExtension == "zip" { Self.folders.store(url) }
            if url.host!.hasPrefix("writeonly-") {
                reply(201, body: Data("<html>Created</html>".utf8), type: "text/html")
            } else {
                reply(201)
            }
        default:
            reply(405)
        }
    }

    private static func listing(host: String, names: [String]) -> String {
        func entry(_ href: String, type: String = "", status: Int = 200) -> String {
            """
            <d:response><d:href>\(href)</d:href>
            <d:propstat><d:prop><d:getlastmodified>Wed, 01 May 2024 00:00:00 GMT</d:getlastmodified>
            <d:resourcetype>\(type)</d:resourcetype><d:getcontentlength>6</d:getcontentlength>
            <d:getetag>"archive"</d:getetag></d:prop><d:status>HTTP/1.1 \(status) Status</d:status></d:propstat>
            <d:propstat><d:prop><d:getetag>ignored</d:getetag></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat>
            </d:response>
            """
        }
        let directory = host.hasPrefix("proxy-") ? "http://internal.test/private/canonical/" : "/dav/My%20Books/Backups/"
        let collection = entry(directory, type: "<d:collection/>")
        if host.hasPrefix("denied-") {
            return #"<d:multistatus xmlns:d="DAV:"><d:response><d:href>/dav/My%20Books/Backups/</d:href><d:status>HTTP/1.1 403 Forbidden</d:status></d:response></d:multistatus>"#
        }
        let saved = names.map { entry(directory + $0) }.joined()
        if host.hasPrefix("proxy-") {
            return """
            <d:multistatus xmlns:d="DAV:">
            \(collection)\(saved)\(entry(directory + oldName))\(entry(directory + recentName))
            \(entry("http://other.test/private/canonical/legado-ios-other.zip"))
            \(entry(directory + "nested/legado-ios-nested.zip"))
            </d:multistatus>
            """
        }
        return """
        <d:multistatus xmlns:d="DAV:">
        \(collection)\(saved)
        \(entry("/dav/My%20Books/Backups/" + oldName))
        \(entry("legado-sync.json"))
        \(entry("https://\(host):443/dav/My%20Books/Backups/" + recentName))
        \(entry("https://unrelated.test/dav/My%20Books/Backups/legado-ios-elsewhere.zip"))
        \(entry("../legado-ios-parent.zip"))
        \(entry("legado-ios-collection.zip", type: "<d:collection/>"))
        <d:response><d:href>legado-ios-deleted.zip</d:href><d:status>HTTP/1.1 404 Not Found</d:status></d:response>
        \(entry("unrelated.txt"))
        \(entry("my-renamed-backup.zip"))
        \(entry("no-metadata.zip", status: 404))
        </d:multistatus>
        """
    }

    private func reply(_ status: Int, body: Data = Data(), type: String = "application/octet-stream") {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }
}
