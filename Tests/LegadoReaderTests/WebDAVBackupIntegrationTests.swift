import XCTest
@testable import Legado

@MainActor
final class WebDAVBackupIntegrationTests: XCTestCase {
    func testExportAndRestoreOnAnEmptyLibraryWithoutAServer() async throws {
        let files = FileManager.default
        let work = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? files.removeItem(at: work) }
        let original = work.appendingPathComponent("Old/Legado", isDirectory: true)
        let installed = work.appendingPathComponent("Fresh/Legado", isDirectory: true)
        let from = try LegadoDatabase(url: original.appendingPathComponent("legado.sqlite3"))
        let fresh = try LegadoDatabase(url: installed.appendingPathComponent("legado.sqlite3"))
        let pref = "backup.test." + UUID().uuidString
        defer { UserDefaults.standard.removeObject(forKey: pref) }
        UserDefaults.standard.set("已选字体颜色", forKey: pref)

        let localBook = original.appendingPathComponent("LocalBooks/海上.txt")
        try files.createDirectory(at: localBook.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("第一章\n这是离线正文。".utf8).write(to: localBook)
        let book = Book(bookUrl: localBook.absoluteString, name: "海上", author: "读者")
        try await from.replaceBooks([book])
        let previousAccount = try WebDAVAccount.load()
        defer {
            if let previousAccount { try? previousAccount.save() } else { try? WebDAVAccount.remove() }
        }
        let savedAccount = WebDAVAccount(directory: "https://restore.example.invalid/阅读", username: "reader", password: UUID().uuidString)
        try savedAccount.save()
        let service = WebDAVBackupService()
        let archive = try await service.createArchive(database: from)
        defer { try? files.removeItem(at: archive) }
        XCTAssertEqual(archive.pathExtension, "zip")
        let local = work.appendingPathComponent("Files", isDirectory: true)
        try WebDAVBackupService.saveLocal(archive, directory: local)
        let saved = local.appendingPathComponent(archive.lastPathComponent)
        let handle = try FileHandle(forReadingFrom: saved)
        XCTAssertEqual(try handle.read(upToCount: 4), Data([80, 75, 3, 4]))
        try handle.close()

        try WebDAVAccount.remove()
        XCTAssertNil(try WebDAVAccount.load())
        UserDefaults.standard.removeObject(forKey: pref)
        let previouslyEmpty = try await fresh.loadBooks()
        XCTAssertTrue(previouslyEmpty.isEmpty)
        var refreshes = 0
        service.didRestore = { refreshes += 1 }
        try await service.restore(from: saved, database: fresh)
        let restoredShelf = try await fresh.loadBooks()
        let restored = try XCTUnwrap(restoredShelf.first)
        let restoredURL = try XCTUnwrap(URL(string: restored.bookUrl))
        XCTAssertEqual(restoredURL.standardizedFileURL.path, installed.appendingPathComponent("LocalBooks/海上.txt").standardizedFileURL.path)
        XCTAssertEqual(try String(contentsOf: restoredURL, encoding: .utf8), "第一章\n这是离线正文。")
        XCTAssertEqual(UserDefaults.standard.string(forKey: pref), "已选字体颜色")
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(try WebDAVAccount.load(), savedAccount)
    }

    func testNewWebDAVDirectoryAndRestoringASelectedVersion() async throws {
        let port = try XCTUnwrap(ProcessInfo.processInfo.environment["LEGADO_TEST_DAV_PORT"],
                                 "The test requires the loopback DAV fixture")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try LegadoDatabase(url: root.appendingPathComponent("a/legado.sqlite3"))
        let other = try LegadoDatabase(url: root.appendingPathComponent("b/legado.sqlite3"))
        let account = WebDAVAccount(directory: "http://127.0.0.1:\(port)/dav/新目录/\(UUID())/备份")
        let client = try account.makeClient()
        let service = WebDAVBackupService()
        let firstBook = Book(bookUrl: "https://example.org/a", name: "原来的书架", author: "")
        let otherBook = Book(bookUrl: "https://example.org/b", name: "另一台设备", author: "")

        try await database.replaceBooks([firstBook])
        guard case .uploaded = try await service.sync(database: database, account: account) else {
            return XCTFail("立即同步应创建目录并上传首份完整 ZIP")
        }
        guard case .unchanged = try await service.sync(database: database, account: account) else {
            return XCTFail("数据未变化时不应新建备份")
        }
        let firstList = try await client.listBackups()
        let first = try XCTUnwrap(firstList.first)

        try await other.replaceBooks([otherBook])
        let upload = try await service.createArchive(database: other)
        defer { try? FileManager.default.removeItem(at: upload) }
        let second = try await client.uploadBackup(from: upload)
        try await database.replaceBooks([])
        guard case .conflict(let conflict) = try await service.sync(database: database, account: account) else {
            return XCTFail("两端都改动时应让用户选择")
        }
        XCTAssertEqual(conflict.remoteName, second.name)
        guard case .restored = try await service.resolve(conflict, preferLocal: false, database: database, account: account) else {
            return XCTFail("选择云端应恢复最新书架")
        }
        let synced = try await database.loadBooks()
        XCTAssertEqual(synced.map(\.name), [otherBook.name])
        try await service.restoreRemote(first, database: database, account: account)
        let historical = try await database.loadBooks()
        XCTAssertEqual(historical.map(\.name), [firstBook.name])
        guard case .conflict = try await service.sync(database: database, account: account) else {
            return XCTFail("手动恢复历史版本后应保留选择权")
        }
        let history = try await client.listBackups()
        XCTAssertEqual(history.map(\.name), [second.name, first.name])
    }

    func testRejectsNonBackupZIPWithoutReplacingTheShelf() async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let db = try LegadoDatabase(url: work.appendingPathComponent("legado.sqlite3"))
        try await db.replaceBooks([Book(bookUrl: "https://example.com/current", name: "现有书架", author: "")])
        let broken = work.appendingPathComponent("incomplete.zip")
        try Data([80, 75, 3, 4, 0]).write(to: broken)
        do {
            try await WebDAVBackupService().restore(from: broken, database: db)
            XCTFail("应拒绝无效备份")
        } catch {}
        let shelf = try await db.loadBooks()
        XCTAssertEqual(shelf.map(\.name), ["现有书架"])
    }
}
