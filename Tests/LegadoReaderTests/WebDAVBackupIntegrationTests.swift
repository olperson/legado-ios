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
