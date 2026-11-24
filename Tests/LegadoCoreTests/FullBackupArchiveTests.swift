import Foundation
import Testing
import ZIPFoundation
@testable import LegadoCore

struct FullBackupArchiveTests {
    private let fm = FileManager.default

    private func storage(in root: URL, name: String) -> FullBackupStorage {
        let container = root.appendingPathComponent(name)
        return .init(support: container.appendingPathComponent("Support"), documents: container.appendingPathComponent("Documents"),
                     speechCache: container.appendingPathComponent("Caches/httpTTS_cache"), defaults: .standard,
                     domain: "test.legado.full." + UUID().uuidString)
    }

    private func write(_ contents: String, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    @Test func restoresFullLibraryAndSettingsOnFreshInstall() async throws {
        let temp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let old = storage(in: temp, name: "old")
        let new = storage(in: temp, name: "new")
        defer {
            try? fm.removeItem(at: temp)
            for store in [old, new] { store.defaults.removePersistentDomain(forName: store.domain) }
        }
        let db = try LegadoDatabase(url: old.support.appendingPathComponent("legado.sqlite3"))
        _ = try await db.recordSearchKeyword("灯塔", at: 92)
        try await db.putCache(.init(key: "rule.variable", value: "token"))
        try await db.putCookie(.init(url: "https://example.test", cookie: "reader=1"))
        try write("字体", to: old.support.appendingPathComponent("fonts/字体.otf"))
        try write("规则", to: old.support.appendingPathComponent("replace-rules.json"))
        try write("audio", to: old.speechCache.appendingPathComponent("abc.audio"))
        try write("note", to: old.documents.appendingPathComponent("笔记.md"))
        try write("another backup", to: old.documents.appendingPathComponent("Backups/old.zip"))
        old.defaults.setPersistentDomain(["textSize": 25, "webdav.schedule.settings": Data([1]),
                                          "webdav.schedule.runtime": 1, "webdav.base.test": "private"],
                                         forName: old.domain)
        let first = temp.appendingPathComponent("first.zip")
        let account = Data("saved account".utf8)
        let hash = try await db.createFullBackup(at: first, connection: account, storage: old)
        #expect(try LegadoDatabase.fullBackupFingerprint(at: first) == hash)
        #expect(try LegadoDatabase.fullBackupConnection(at: first) == account)
        let savedBackup = old.documents.appendingPathComponent("归档/保存.zip")
        try fm.createDirectory(at: savedBackup.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: first, to: savedBackup)
        #expect(try await db.createFullBackup(at: temp.appendingPathComponent("second.zip"), connection: account, storage: old) == hash)
        #expect(try Archive(url: first, accessMode: .read)["Documents/Backups/old.zip"] == nil)
        #expect(try Archive(url: temp.appendingPathComponent("second.zip"), accessMode: .read)["Documents/归档/保存.zip"] == nil)

        let dbURL = new.support.appendingPathComponent("legado.sqlite3")
        let fresh = try LegadoDatabase(url: dbURL)
        let reader = try LegadoDatabase(url: dbURL)
        let localBackup = new.documents.appendingPathComponent("已下载/上次备份.zip")
        try fm.createDirectory(at: localBackup.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: first, to: localBackup)
        new.defaults.setPersistentDomain(["webdav.schedule.runtime": 7], forName: new.domain)
        #expect(try await fresh.restoreFullBackup(from: first, storage: new) == account)
        #expect(try await reader.cacheValue(for: "rule.variable", now: 0) == "token")
        #expect(try await reader.cookie(for: "https://example.test")?.cookie == "reader=1")
        #expect(try await reader.loadSearchKeywords(order: .usage).map(\.word) == ["灯塔"])
        #expect(try Data(contentsOf: new.support.appendingPathComponent("fonts/字体.otf")) == Data("字体".utf8))
        #expect(try Data(contentsOf: new.speechCache.appendingPathComponent("abc.audio")) == Data("audio".utf8))
        #expect(try Data(contentsOf: new.documents.appendingPathComponent("笔记.md")) == Data("note".utf8))
        #expect(try LegadoDatabase.fullBackupFingerprint(at: localBackup) == hash)
        #expect(new.preferences()["textSize"] as? Int == 25)
        #expect(new.preferences()["webdav.schedule.settings"] as? Data == Data([1]))
        #expect(new.preferences()["webdav.schedule.runtime"] as? Int == 7)
        #expect(new.preferences()["webdav.base.test"] == nil)
    }

    @Test func rollsBackChangedFilesAndDatabaseOnInstallationFailure() async throws {
        let temp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = storage(in: temp, name: "source")
        let target = storage(in: temp, name: "target")
        defer {
            try? fm.removeItem(at: temp)
            for store in [source, target] { store.defaults.removePersistentDomain(forName: store.domain) }
        }
        let incoming = try LegadoDatabase(url: source.support.appendingPathComponent("legado.sqlite3"))
        let current = try LegadoDatabase(url: target.support.appendingPathComponent("legado.sqlite3"))
        for (database, store, value) in [(incoming, source, "new"), (current, target, "old")] {
            try await database.putCache(.init(key: "key", value: value))
            try write(value, to: store.support.appendingPathComponent("reader-background.jpg"))
            try write(value, to: store.documents.appendingPathComponent("annotation.txt"))
            store.defaults.setPersistentDomain(["marker": value], forName: store.domain)
        }
        try write("voice", to: source.speechCache.appendingPathComponent("word.audio"))
        // The last root cannot be created, after Support and Documents have already been installed.
        try write("occupied", to: target.speechCache.deletingLastPathComponent())
        let zip = temp.appendingPathComponent("backup.zip")
        try await incoming.createFullBackup(at: zip, connection: nil, storage: source)
        await #expect(throws: (any Error).self) { try await current.restoreFullBackup(from: zip, storage: target) }
        #expect(try await current.cacheValue(for: "key", now: 0) == "old")
        #expect(target.preferences()["marker"] as? String == "old")
        #expect(try Data(contentsOf: target.support.appendingPathComponent("reader-background.jpg")) == Data("old".utf8))
        #expect(try Data(contentsOf: target.documents.appendingPathComponent("annotation.txt")) == Data("old".utf8))
        #expect(!fm.fileExists(atPath: target.journal.path))

        // Tampering is rejected during staging and never reaches installation.
        let archive = try Archive(url: zip, accessMode: .update)
        try archive.remove(try #require(archive["preferences.plist"]))
        await #expect(throws: (any Error).self) { try await current.restoreFullBackup(from: zip, storage: target) }
        #expect(try await current.cacheValue(for: "key", now: 0) == "old")
        #expect(!fm.fileExists(atPath: target.journal.path))
    }
}
