import CryptoKit
import Foundation
import SQLite3

/// Local book URLs double as shelf identifiers. Restoring a file into a new sandbox
/// must move every reference, including filenames derived from the old identifier.
enum FullBackupPortability {
    static func rebase(database: OpaquePointer, assets: URL, sourceRoot: URL, destinationRoot: URL,
                       preferences: inout [String: Any]) throws {
        let files = FileManager.default
        let support = assets.appendingPathComponent("Support", isDirectory: true)
        let target = destinationRoot.appendingPathComponent("LocalBooks", isDirectory: true)
        var moved: [String: String] = [:]

        func relocated(_ value: String) -> String {
            guard value.hasPrefix("file:"), let url = URL(string: value), url.isFileURL,
                  url.host?.isEmpty != false || url.host == "localhost" else { return value }
            let parent = url.deletingLastPathComponent().lastPathComponent
            let name = url.lastPathComponent
            guard parent == "LocalBooks", !name.isEmpty, name != ".", name != "..",
                  !name.contains("/"), !name.contains("\\"), !name.contains("\0") else { return value }
            return target.appendingPathComponent(name, isDirectory: false).absoluteString
        }
        func rebaseRecord(_ record: inout [String: Any]) -> Bool {
            var changed = false
            // Only rewrite file-reference fields. Rule expressions and user text can
            // contain a file URL as literal content and must be preserved verbatim.
            for key in ["bookUrl", "tocUrl", "baseUrl", "url", "coverUrl", "customCoverUrl", "imgUrl", "imageURL", "resourceUrl"] {
                guard let old = record[key] as? String else { continue }
                let new = relocated(old)
                guard old != new else { continue }
                record[key] = new
                if key == "bookUrl" { moved[old] = new }
                changed = true
            }
            return changed
        }
        // ON UPDATE CASCADE moves the chapter index when the shelf identifier changes.
        // Chapter payloads (and formerly unindexed file-backed books) still need rebasing.
        try rewriteRows(database: database, chapters: false, transform: rebaseRecord)
        try rewriteRows(database: database, chapters: true, transform: rebaseRecord)

        let legacyShelf = support.appendingPathComponent("books.json")
        if files.fileExists(atPath: legacyShelf.path) {
            try rewriteLegacyArray(at: legacyShelf, transform: rebaseRecord)
        }
        let legacyChapters = support.appendingPathComponent("Chapters", isDirectory: true)
        if files.fileExists(atPath: legacyChapters.path) {
            for file in try files.contentsOfDirectory(at: legacyChapters, includingPropertiesForKeys: nil)
                where file.pathExtension.lowercased() == "json" {
                var owner: String?
                try rewriteLegacyArray(at: file) { record in
                    let changed = rebaseRecord(&record)
                    if changed { owner = record["bookUrl"] as? String }
                    return changed
                }
                if let owner {
                    let destination = legacyChapters.appendingPathComponent(digest(owner) + ".json")
                    if destination != file { try files.moveItem(at: file, to: destination) }
                }
            }
        }

        if let data = preferences["pendingBookReadingProgress"] as? Data {
            let old = try JSONDecoder().decode([String: BookProgress].self, from: data)
            var result: [String: BookProgress] = [:]
            for (key, progress) in old {
                let new = relocated(key)
                if new != key { moved[key] = new }
                // Old sandboxes can contain more than one pending entry for the same file.
                if result[new].map({ $0.durChapterTime >= progress.durChapterTime }) != true {
                    result[new] = progress
                }
            }
            if old != result { preferences["pendingBookReadingProgress"] = try JSONEncoder().encode(result) }
        }
        if let font = preferences["textFont"] as? String, font.hasPrefix("/") {
            preferences["textFont"] = URL(fileURLWithPath: font).lastPathComponent
        }

        // Edits to a TXT/EPUB may be cached even when the book hasn't been added to the shelf.
        let localBooks = support.appendingPathComponent("LocalBooks", isDirectory: true)
        if files.fileExists(atPath: localBooks.path) {
            let original = sourceRoot.appendingPathComponent("LocalBooks", isDirectory: true)
            for url in try files.contentsOfDirectory(at: localBooks, includingPropertiesForKeys: nil)
                where LocalBookService.supports(url) {
                let key = original.appendingPathComponent(url.lastPathComponent, isDirectory: false).absoluteString
                let new = relocated(key)
                if key != new { moved[key] = new }
            }
        }
        let contentDirectory = support.appendingPathComponent("ChapterContent", isDirectory: true)
        guard !moved.isEmpty, files.fileExists(atPath: contentDirectory.path) else { return }
        let oldHashes = Set(moved.keys.map(digest))
        for file in try files.contentsOfDirectory(at: contentDirectory, includingPropertiesForKeys: nil)
            where file.pathExtension == "json" && oldHashes.contains(String(file.lastPathComponent.prefix(64))) {
            var entry = try JSONDecoder().decode(CachedChapterContent.self, from: Data(contentsOf: file))
            guard let bookURL = moved[entry.bookURL] else { continue }
            entry.bookURL = bookURL
            entry.chapterURL = relocated(entry.chapterURL)
            let name = digest(bookURL) + "-" + digest(entry.chapterURL) + ".json"
            let destination = contentDirectory.appendingPathComponent(name)
            if destination != file, files.fileExists(atPath: destination.path) {
                let existing = try JSONDecoder().decode(CachedChapterContent.self, from: Data(contentsOf: destination))
                if existing.savedAt >= entry.savedAt {
                    try files.removeItem(at: file)
                    continue
                }
            }
            try JSONEncoder().encode(entry).write(to: destination, options: .atomic)
            if destination != file { try files.removeItem(at: file) }
        }
    }

    private static func rewriteLegacyArray(at file: URL, transform: (inout [String: Any]) -> Bool) throws {
        guard var records = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var changed = false
        for index in records.indices where transform(&records[index]) { changed = true }
        if changed { try JSONSerialization.data(withJSONObject: records).write(to: file, options: .atomic) }
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func rewriteRows(database: OpaquePointer, chapters: Bool,
                                    transform: (inout [String: Any]) -> Bool) throws {
        let table = chapters ? "chapters" : "books"
        let readSQL = "SELECT rowid, payload FROM \(table) WHERE rowid > ? AND book_url LIKE 'file:%' ORDER BY rowid LIMIT 1"
        let writeSQL = chapters
            ? "UPDATE chapters SET book_url = ?2, payload = ?3, url = ?4 WHERE rowid = ?1"
            : "UPDATE books SET book_url = ?2, payload = ?3 WHERE rowid = ?1"
        func statement(_ sql: String) throws -> OpaquePointer {
            var value: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &value, nil) == SQLITE_OK, let value else {
                throw LegadoDatabaseError.prepare(String(cString: sqlite3_errmsg(database)))
            }
            return value
        }
        let read = try statement(readSQL)
        defer { sqlite3_finalize(read) }
        let write = try statement(writeSQL)
        defer { sqlite3_finalize(write) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var row: Int64 = .min
        while true {
            sqlite3_reset(read)
            sqlite3_bind_int64(read, 1, row)
            let status = sqlite3_step(read)
            if status == SQLITE_DONE { return }
            guard status == SQLITE_ROW, let bytes = sqlite3_column_blob(read, 1) else {
                throw LegadoDatabaseError.execute(String(cString: sqlite3_errmsg(database)))
            }
            row = sqlite3_column_int64(read, 0)
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(read, 1)))
            sqlite3_reset(read)
            guard var record = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            guard transform(&record) else { continue }
            guard let key = record["bookUrl"] as? String else { throw CocoaError(.fileReadCorruptFile) }
            let updated = try JSONSerialization.data(withJSONObject: record)
            sqlite3_reset(write)
            sqlite3_bind_int64(write, 1, row)
            sqlite3_bind_text(write, 2, key, -1, transient)
            let bound = updated.withUnsafeBytes { sqlite3_bind_blob(write, 3, $0.baseAddress, Int32($0.count), transient) }
            guard bound == SQLITE_OK else { throw LegadoDatabaseError.bind(String(cString: sqlite3_errmsg(database))) }
            if chapters {
                guard let url = record["url"] as? String else { throw CocoaError(.fileReadCorruptFile) }
                sqlite3_bind_text(write, 4, url, -1, transient)
            }
            guard sqlite3_step(write) == SQLITE_DONE else {
                throw LegadoDatabaseError.execute(String(cString: sqlite3_errmsg(database)))
            }
        }
    }
}
