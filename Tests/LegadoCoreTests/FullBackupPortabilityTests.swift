import Foundation
import Testing
@testable import LegadoCore

struct FullBackupPortabilityTests {
    @Test func restoresLocalBookAndItsReadingStateAcrossContainers() async throws {
        let fm = FileManager.default
        let workspace = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = workspace.appendingPathComponent("old", isDirectory: true)
        let target = workspace.appendingPathComponent("new", isDirectory: true)
        let sourceDomain = UUID().uuidString
        let targetDomain = UUID().uuidString
        defer {
            UserDefaults.standard.removePersistentDomain(forName: sourceDomain)
            UserDefaults.standard.removePersistentDomain(forName: targetDomain)
            try? fm.removeItem(at: workspace)
        }
        let original = source.appendingPathComponent("LocalBooks/池 塘.txt", isDirectory: false)
        let restored = target.appendingPathComponent("LocalBooks/池 塘.txt", isDirectory: false)
        try fm.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("第一章\n池畔晚风".utf8).write(to: original)

        // An in-place iOS upgrade can already have changed the container before backup.
        let stale = workspace.appendingPathComponent("previous-install/LocalBooks/池 塘.txt", isDirectory: false).absoluteString
        var book = Book(bookUrl: stale, name: "池塘")
        book.durChapterPos = 2
        var chapter = BookChapter(url: "local://chapter/0", title: "第一章", bookUrl: stale, index: 0)
        chapter.baseUrl = stale
        let database = try LegadoDatabase(url: source.appendingPathComponent("legado.sqlite3"))
        try await database.replaceBooks([book])
        try await database.replaceChapters([chapter], bookURL: stale)
        let sourceCache = ChapterContentCache(directory: source.appendingPathComponent("ChapterContent"))
        try await sourceCache.save(.init(bookURL: stale, chapterURL: chapter.url, content: "手动编辑过的正文"))
        let toc = FileBookChapterRepository(directory: source.appendingPathComponent("Chapters"))
        try await toc.save([chapter], bookURL: stale)
        try JSONEncoder().encode([book]).write(to: source.appendingPathComponent("books.json"))
        let progress = try JSONEncoder().encode([stale: BookProgress(book: book)])
        UserDefaults.standard.setPersistentDomain(["textFont": "/old/fonts/myscript.ttf", "pendingBookReadingProgress": progress],
                                                 forName: sourceDomain)

        let archive = workspace.appendingPathComponent("backup.zip")
        try await writeBackup(database, source, archive, sourceDomain)
        let empty = try LegadoDatabase(url: target.appendingPathComponent("legado.sqlite3"))
        try await readBackup(empty, target, archive, targetDomain)

        let shelf = try await empty.loadBooks()
        #expect(shelf.map(\.bookUrl) == [restored.absoluteString])
        #expect(shelf.first?.durChapterPos == 2)
        #expect(try Data(contentsOf: restored) == Data(contentsOf: original))
        let restoredTOC = try await empty.loadChapters(bookURL: restored.absoluteString)
        #expect(restoredTOC.first?.baseUrl == restored.absoluteString)
        #expect(restoredTOC.first?.bookUrl == restored.absoluteString)
        let restoredCache = ChapterContentCache(directory: target.appendingPathComponent("ChapterContent"))
        let entry = try await restoredCache.load(bookURL: restored.absoluteString, chapterURL: chapter.url)
        #expect(entry?.content == "手动编辑过的正文")
        let legacyTOC = FileBookChapterRepository(directory: target.appendingPathComponent("Chapters"))
        let legacyChapters = try await legacyTOC.load(bookURL: restored.absoluteString)
        #expect(legacyChapters == restoredTOC)
        let legacyShelf = try JSONDecoder().decode([Book].self, from: Data(contentsOf: target.appendingPathComponent("books.json")))
        #expect(legacyShelf == shelf)
        let preferences = try #require(UserDefaults.standard.persistentDomain(forName: targetDomain))
        #expect(preferences["textFont"] as? String == "myscript.ttf")
        let saved = try #require(preferences["pendingBookReadingProgress"] as? Data)
        let pending = try JSONDecoder().decode([String: BookProgress].self, from: saved)
        #expect(pending == [restored.absoluteString: BookProgress(book: book)])
    }

    private func storage(_ support: URL, _ domain: String) -> FullBackupStorage {
        .init(support: support, documents: support.appendingPathExtension("documents"),
              speechCache: support.appendingPathExtension("speech"), defaults: .standard, domain: domain)
    }

    private func writeBackup(_ db: isolated LegadoDatabase, _ support: URL, _ url: URL, _ domain: String) throws {
        _ = try db.createFullBackup(at: url, connection: nil, storage: storage(support, domain))
    }

    private func readBackup(_ db: isolated LegadoDatabase, _ support: URL, _ url: URL, _ domain: String) throws {
        _ = try db.restoreFullBackup(from: url, storage: storage(support, domain))
    }
}
