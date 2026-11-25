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
        let client = try makeClient()
        try await client.upload(Data("{}".utf8), replacing: nil)
        let files = try await client.listBackups()
        #expect(files.map(\.isLegacySnapshot).contains(true))
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
        #expect(manual.count == files.count + 1)
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
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: archive) }
        try BackupDAVProtocol.archive.write(to: archive)
        let saved = try await client.uploadBackup(from: archive)
        #expect(try await client.listBackups().contains { $0.name == saved.name })
    }

    @Test func reportsPutSuccessWhenHistoryNeverContainsTheZIPAsUnconfirmed() async throws {
        let client = try makeClient(mode: "discard")
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: archive) }
        try BackupDAVProtocol.archive.write(to: archive)
        do {
            _ = try await client.uploadBackup(from: archive)
            Issue.record("A successful PUT alone must not report that the ZIP is restorable.")
        } catch WebDAVSyncError.uploadNotListed(let name) {
            #expect(name.hasPrefix("legado-ios-") && name.hasSuffix(".zip"))
        }
    }

    @Test func manualSyncStillChecksHistoryIfDepthZeroIsUnsupported() async throws {
        let client = try makeClient(mode: "discard-no-depth-zero")
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: archive) }
        try BackupDAVProtocol.archive.write(to: archive)
        #expect(try await !client.listBackups().isEmpty)
        do {
            _ = try await client.uploadBackup(from: archive, requireListing: true)
            Issue.record("A readable Depth: 1 history must contain the uploaded ZIP even when Depth: 0 is unavailable.")
        } catch WebDAVSyncError.uploadNotListed(let name) {
            #expect(name.hasSuffix(".zip"))
        }
    }

    @Test func reportsDeniedDirectoryInsideMultiStatus() async throws {
        let client = try makeClient(mode: "denied")
        await #expect(throws: WebDAVSyncError.forbidden) { try await client.listBackups() }
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
            return created.contains(folder)
        }
    }

    private static let folders = Collections()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url,
              request.value(forHTTPHeaderField: "Authorization") == "Basic cmVhZGVyOnRlc3Q=" else {
            reply(401)
            return
        }
        switch request.httpMethod {
        case "MKCOL":
            reply(Self.folders.create(url))
        case "PROPFIND":
            guard Self.folders.has(url) else { reply(404); return }
            if url.host?.hasPrefix("discard-no-depth-zero-") == true, request.value(forHTTPHeaderField: "Depth") == "0" {
                reply(405)
                return
            }
            guard ["0", "1"].contains(request.value(forHTTPHeaderField: "Depth") ?? "") else { reply(400); return }
            let xml = Self.listing(host: url.host!, depth: request.value(forHTTPHeaderField: "Depth"),
                                   names: Self.folders.names(in: url))
            reply(207, body: Data(xml.utf8), type: "application/xml")
        case "PUT":
            guard Self.folders.has(url.deletingLastPathComponent()) else { reply(409); return }
            guard request.value(forHTTPHeaderField: "If-None-Match") == "*" else { reply(428); return }
            if url.pathExtension == "zip", !(url.host?.hasPrefix("discard-") ?? false) { Self.folders.store(url) }
            reply(201)
        default:
            reply(405)
        }
    }

    private static func listing(host: String, depth: String?, names: [String]) -> String {
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
        if depth == "0" { return "<d:multistatus xmlns:d=\"DAV:\">" + collection + "</d:multistatus>" }
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
        \(entry("legado-ios-deleted.zip", status: 404))
        \(entry("unrelated.txt"))
        \(entry("my-renamed-backup.zip"))
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
