import CryptoKit
import Foundation
import SQLite3
import ZIPFoundation

/// Each root contains data owned by the app. Never archive the whole Library directory.
// UserDefaults supports concurrent callers. All other members are immutable value types.
struct FullBackupStorage: @unchecked Sendable {
    let support: URL
    let documents: URL
    let speechCache: URL
    let defaults: UserDefaults
    let domain: String

    static func live(support: URL) -> Self {
        let fm = FileManager.default
        return Self(support: support, documents: fm.urls(for: .documentDirectory, in: .userDomainMask)[0],
                    speechCache: fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Legado/httpTTS_cache"),
                    defaults: .standard, domain: Bundle.main.bundleIdentifier ?? "com.epiboly.legado")
    }

    var roots: [(name: String, url: URL)] {
        [("Support", support), ("Documents", documents), ("SpeechCache", speechCache)]
    }
    var journal: URL { support.appendingPathComponent(".legado-restore") }

    func preferences() -> [String: Any] { defaults.persistentDomain(forName: domain) ?? [:] }

    static func isPortablePreference(_ key: String) -> Bool {
        !key.hasPrefix("webdav.base.") && !key.hasPrefix("webdav.fullSync.") && key != "webdav.schedule.runtime"
    }
}

enum FullBackupArchive {
    private static let fm = FileManager.default
    private static let installLock = NSRecursiveLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let marker = "legado.fullRestore."
    private static let sessionMarker = "legado.pendingBackupSession."
    private static let dbFile = "library.sqlite"
    private static let prefsFile = "preferences.plist"
    private static let connectionFile = "account.dat"
    private static let indexFile = "manifest.json"

    struct Manifest: Codable {
        let format: String
        let version: Int
        let sourceRoot: URL
        let files: [String: String]
        let databaseFingerprint: String
        let fingerprint: String
    }

    private struct Change: Codable {
        let root: String
        let name: String
        let hadOriginal: Bool
    }

    private struct Install: Codable {
        let id: UUID
        let changes: [Change]
    }

    private static func invalid(_ reason: String) -> LegadoDatabaseError {
        .decode("无法恢复完整备份：" + reason)
    }

    private static func digest(_ data: Data) -> String { hex(SHA256.hash(data: data)) }
    private static func hex(_ hash: SHA256.Digest) -> String { hash.map { String(format: "%02x", $0) }.joined() }

    private static func temporaryDirectory() throws -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent("legado-backup-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private static func propertyList(_ preferences: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: preferences, format: .xml, options: 0)
    }

    private static func readPreferences(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let result = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw invalid("偏好设置格式有误。")
        }
        return result
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    // Calculate from content only. ZIP timestamps and SQLite's physical page layout
    // can change without the user changing a single book or setting.
    private static func fingerprint(files: [String: String], database: String) throws -> String {
        var parts = files
        parts[dbFile] = database
        return digest(try encode(parts))
    }

    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
            && !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
    }

    private static func isAsset(root: String, name: String, databaseName: String) -> Bool {
        let name = name.precomposedStringWithCanonicalMapping.lowercased()
        if root == "Support" {
            let sql = databaseName.lowercased()
            return ![sql, sql + "-wal", sql + "-shm", sql + "-journal", ".legado-restore"].contains(name)
        }
        if root == "Documents" { return name != "backups" }
        return root == "SpeechCache"
    }

    private static func names(in directory: URL) throws -> [String] {
        guard fm.fileExists(atPath: directory.path) else { return [] }
        return try fm.contentsOfDirectory(atPath: directory.path).sorted()
    }

    static func create(database: OpaquePointer, storage: FullBackupStorage, at url: URL, connection: Data?) throws -> String {
        let stage = try temporaryDirectory()
        defer { try? fm.removeItem(at: stage) }
        let dbCopy = stage.appendingPathComponent(dbFile)
        let logicalDigest = try withDatabase(at: dbCopy, create: true) { copy in
            try copyDatabase(from: database, to: copy)
            // Never copy pending installation records (including a former account) to another backup.
            try sql(copy, "PRAGMA secure_delete = ON")
            try clearInstallRecords(copy)
            return try databaseFingerprint(copy)
        }
        let result = stage.appendingPathComponent("backup.zip")
        let archive = try Archive(url: result, accessMode: .create)
        var files = [String: String]()
        func add(_ name: String, data: Data) throws {
            try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { offset, size in
                data.subdata(in: Int(offset)..<(Int(offset) + size))
            }
            files[name] = digest(data)
        }
        func addFile(_ name: String, file: URL) throws {
            let reader = try FileHandle(forReadingFrom: file)
            defer { try? reader.close() }
            let size = try reader.seekToEnd()
            guard let length = Int64(exactly: size) else { throw CocoaError(.fileReadTooLarge) }
            try reader.seek(toOffset: 0)
            var hasher = SHA256()
            try archive.addEntry(with: name, type: .file, uncompressedSize: length, compressionMethod: .deflate,
                                 bufferSize: 64 * 1024) { _, count in
                try Task.checkCancellation()
                let chunk = try reader.read(upToCount: count) ?? Data()
                guard chunk.count == count else { throw CocoaError(.fileReadCorruptFile) }
                hasher.update(data: chunk)
                return chunk
            }
            files[name] = hex(hasher.finalize())
        }
        try addFile(dbFile, file: dbCopy)
        try add(prefsFile, data: propertyList(storage.preferences().filter { FullBackupStorage.isPortablePreference($0.key) }))
        if let connection { try add(connectionFile, data: connection) }
        let databaseName = liveFilename(database)
        func visit(_ directory: URL, prefix: String) throws {
            for name in try names(in: directory) {
                try Task.checkCancellation()
                guard validName(name) else { throw invalid("文件名无效。") }
                if !prefix.contains("/") && !isAsset(root: prefix, name: name, databaseName: databaseName) { continue }
                let item = directory.appendingPathComponent(name)
                let values = try item.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { continue }
                let key = prefix + "/" + name
                if values.isDirectory == true { try visit(item, prefix: key) }
                else if values.isRegularFile == true {
                    if key.hasPrefix("Documents/"), isLocalBackup(item) { continue }
                    try addFile(key, file: item)
                }
            }
        }
        for root in storage.roots { try visit(root.url, prefix: root.name) }
        let manifest = try Manifest(format: "legado-ios-full-backup", version: 1, sourceRoot: storage.support,
                                    files: files, databaseFingerprint: logicalDigest,
                                    fingerprint: fingerprint(files: files, database: logicalDigest))
        try add(indexFile, data: encode(manifest))
        try fm.moveItem(at: result, to: url)
        return manifest.fingerprint
    }

    // Read metadata on its own so callers can compare versions or validate the
    // optional connection before touching the live Keychain, database or files.
    static func metadata(at url: URL) throws -> Manifest {
        try manifest(in: Archive(url: url, accessMode: .read))
    }

    static func connection(at url: URL) throws -> Data? {
        let archive = try Archive(url: url, accessMode: .read)
        let manifest = try manifest(in: archive)
        guard let expected = manifest.files[connectionFile] else { return nil }
        let data = try metadataEntry(connectionFile, in: archive, maximum: 32 << 20)
        guard digest(data) == expected else { throw invalid("连接信息校验失败。") }
        return data
    }

    private static func metadataEntry(_ name: String, in archive: Archive, maximum: Int) throws -> Data {
        guard let entry = archive[name], entry.type == .file, entry.uncompressedSize <= UInt64(maximum) else {
            throw invalid("缺少有效的" + name + "。")
        }
        var data = Data()
        let crc = try archive.extract(entry) { chunk in
            guard chunk.count <= maximum - data.count else { throw invalid("元数据超出声明大小。") }
            data.append(chunk)
        }
        guard crc == entry.checksum, UInt64(data.count) == entry.uncompressedSize else { throw invalid("元数据校验失败。") }
        return data
    }

    private static func manifest(in archive: Archive) throws -> Manifest {
        let manifest = try JSONDecoder().decode(Manifest.self, from: metadataEntry(indexFile, in: archive, maximum: 32 << 20))
        guard manifest.format == "legado-ios-full-backup", manifest.version == 1,
              manifest.sourceRoot.isFileURL, manifest.files[dbFile] != nil, manifest.files[prefsFile] != nil,
              manifest.files[indexFile] == nil,
              try fingerprint(files: manifest.files, database: manifest.databaseFingerprint) == manifest.fingerprint else {
            throw invalid("备份格式或清单校验有误。")
        }
        return manifest
    }

    private static func unpack(_ archive: Archive, manifest: Manifest, into stage: URL, databaseName: String) throws {
        var seen = Set<String>()
        var seenNames = Set<String>()
        var available = ((try? fm.attributesOfFileSystem(forPath: stage.path)[.systemFreeSize]) as? NSNumber)?.uint64Value ?? UInt64.max
        for entry in archive {
            try Task.checkCancellation()
            let name = entry.path
            guard seen.insert(name).inserted, seenNames.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted else {
                throw invalid("备份中有重复文件。")
            }
            if name == indexFile { continue }
            let parts = name.components(separatedBy: "/")
            let metadata = [dbFile, prefsFile, connectionFile].contains(name)
            guard entry.type == .file, let expected = manifest.files[name], parts.allSatisfy(validName),
                  metadata || (parts.count >= 2 && isAsset(root: parts[0], name: parts[1], databaseName: databaseName)) else {
                throw invalid("包含未识别的文件路径。")
            }
            if [prefsFile, connectionFile].contains(name), entry.uncompressedSize > 32 << 20 { throw invalid("配置文件过大。") }
            guard entry.uncompressedSize <= available else { throw CocoaError(.fileWriteOutOfSpace) }
            available -= entry.uncompressedSize
            let target = stage.appendingPathComponent(name)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard !fm.fileExists(atPath: target.path), fm.createFile(atPath: target.path, contents: nil) else {
                throw invalid("无法暂存备份文件。")
            }
            let writer = try FileHandle(forWritingTo: target)
            defer { try? writer.close() }
            var bytes: UInt64 = 0
            var hasher = SHA256()
            let crc = try archive.extract(entry, bufferSize: 64 * 1024) { chunk in
                try Task.checkCancellation()
                guard UInt64(chunk.count) <= entry.uncompressedSize - bytes else { throw invalid("文件长度有误。") }
                bytes += UInt64(chunk.count)
                hasher.update(data: chunk)
                try writer.write(contentsOf: chunk)
            }
            guard bytes == entry.uncompressedSize, crc == entry.checksum, hex(hasher.finalize()) == expected else {
                throw invalid("文件校验失败：" + name)
            }
        }
        guard seen == Set(manifest.files.keys).union([indexFile]) else { throw invalid("备份文件不完整。") }
    }

    // A Files export may have been saved anywhere in Documents. Keep these archives
    // outside subsequent backups and preserve them when restoring another version.
    private static func isLocalBackup(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "zip" && (try? metadata(at: url)) != nil
    }

    private static func preserveLocalBackups(documents: URL, stage: URL) throws {
        func preserve(_ directory: URL, under target: URL) throws {
            for name in try names(in: directory) {
                if directory == documents && name.lowercased() == "backups" { continue }
                let file = directory.appendingPathComponent(name)
                let saved = target.appendingPathComponent(name)
                let attrs = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
                if attrs.isSymbolicLink == true { continue }
                if attrs.isDirectory == true { try preserve(file, under: saved) }
                else if attrs.isRegularFile == true && isLocalBackup(file) {
                    try fm.createDirectory(at: target, withIntermediateDirectories: true)
                    if fm.fileExists(atPath: saved.path) { throw invalid("现有备份文件与待恢复的文档重名：" + name) }
                    do { try fm.linkItem(at: file, to: saved) }
                    catch { try fm.copyItem(at: file, to: saved) }
                }
            }
        }
        try preserve(documents, under: stage.appendingPathComponent("Documents"))
    }

    static func restore(database: OpaquePointer, storage: FullBackupStorage, from url: URL) throws -> Data? {
        let stage = try temporaryDirectory()
        defer { try? fm.removeItem(at: stage) }
        let archive = try Archive(url: url, accessMode: .read)
        let manifest = try manifest(in: archive)
        let databaseName = liveFilename(database)
        try unpack(archive, manifest: manifest, into: stage, databaseName: databaseName)
        try preserveLocalBackups(documents: storage.documents, stage: stage)
        let connection = try manifest.files[connectionFile].map { _ in try Data(contentsOf: stage.appendingPathComponent(connectionFile)) }
        var settings = try readPreferences(stage.appendingPathComponent(prefsFile)).filter { FullBackupStorage.isPortablePreference($0.key) }
        let source = stage.appendingPathComponent(dbFile)
        try withDatabase(at: source, create: false) { staged in
            let sql = "SELECT type,name,tbl_name,coalesce(sql,'') FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type,name"
            guard try rows(staged, sql) == rows(database, sql),
                  try rows(staged, "PRAGMA user_version") == rows(database, "PRAGMA user_version"),
                  try rows(staged, "PRAGMA quick_check") == [["ok"]],
                  try rows(staged, "PRAGMA foreign_key_check").isEmpty,
                  try databaseFingerprint(staged) == manifest.databaseFingerprint else {
                throw invalid("数据库结构、版本或内容校验失败。")
            }
            try FullBackupPortability.rebase(database: staged, assets: stage, sourceRoot: manifest.sourceRoot,
                                             destinationRoot: storage.support, preferences: &settings)
        }
        try Task.checkCancellation()
        try installLock.withLock {
            try recoverLocked(database: database, storage: storage)
            let journal = storage.journal
            try fm.createDirectory(at: journal, withIntermediateDirectories: true)
            let install: Install
            do {
                var changes = [Change]()
                for root in storage.roots {
                    let original = Set(try names(in: root.url).filter { isAsset(root: root.name, name: $0, databaseName: databaseName) })
                    let incoming = try names(in: stage.appendingPathComponent(root.name))
                    for name in original.union(incoming).sorted() {
                        guard validName(name) else { throw invalid("本机目录中含有无法恢复的文件名。") }
                        changes.append(Change(root: root.name, name: name, hadOriginal: original.contains(name)))
                    }
                }
                install = Install(id: UUID(), changes: changes)
                try propertyList(storage.preferences()).write(to: journal.appendingPathComponent(prefsFile), options: .atomic)
                try encode(install).write(to: journal.appendingPathComponent("install.json"), options: .atomic)
            } catch {
                try? fm.removeItem(at: journal)
                throw error
            }

            do {
                // Import through the existing connection so other live WAL readers see the change.
                // The marker commits in the same SQLite transaction as the restored rows.
                try attach(source, to: database)
                defer { try? sql(database, "DETACH DATABASE incoming_backup") }
                try sql(database, "BEGIN IMMEDIATE")
                do {
                    try sql(database, "PRAGMA defer_foreign_keys = ON")
                    let tables = try tableNames(database)
                    for table in tables { try sql(database, "DELETE FROM main." + quoted(table)) }
                    for table in tables {
                        let identifier = quoted(table)
                        try sql(database, "INSERT INTO main." + identifier + " SELECT * FROM incoming_backup." + identifier)
                    }
                    try clearInstallRecords(database)
                    if let connection {
                        try sessionSQL(database, "INSERT INTO legacy_imports(key) VALUES(?)", data: connection)
                    }
                    try sql(database, "INSERT INTO legacy_imports(key) VALUES('" + marker + install.id.uuidString + "')")
                    guard try rows(database, "PRAGMA main.foreign_key_check").isEmpty else { throw invalid("数据库中含有无效关联。") }

                    for root in storage.roots {
                        let originals = journal.appendingPathComponent(root.name)
                        try fm.createDirectory(at: originals, withIntermediateDirectories: true)
                        try fm.createDirectory(at: root.url, withIntermediateDirectories: true)
                        for item in install.changes where item.root == root.name && item.hadOriginal {
                            try fm.moveItem(at: root.url.appendingPathComponent(item.name), to: originals.appendingPathComponent(item.name))
                        }
                        let incoming = stage.appendingPathComponent(root.name)
                        for name in try names(in: incoming) {
                            try fm.moveItem(at: incoming.appendingPathComponent(name), to: root.url.appendingPathComponent(name))
                        }
                    }
                    // Keep this device's sync baselines and schedule bookkeeping out of a portable restore.
                    let runtime = storage.preferences().filter { !FullBackupStorage.isPortablePreference($0.key) }
                    storage.defaults.setPersistentDomain(settings.merging(runtime) { _, local in local }, forName: storage.domain)
                    guard storage.defaults.synchronize() else { throw invalid("无法保存恢复后的偏好设置。") }
                    try sql(database, "COMMIT")
                } catch {
                    try? sql(database, "ROLLBACK")
                    throw error
                }
            } catch {
                try recoverLocked(database: database, storage: storage)
                throw error
            }
            // A cleanup error after commit leaves a recoverable journal; the restored data is live.
            try? recoverLocked(database: database, storage: storage)
        }
        return connection
    }

    // The Keychain and WebKit jars cannot join SQLite's transaction. Keep the
    // pending external state until both stores have acknowledged installation.
    static func pendingSession(_ database: OpaquePointer) throws -> Data? {
        let values = try rows(database, "SELECT key FROM legacy_imports WHERE key GLOB 'legado.pendingBackupSession.*'")
        guard let key = values.first?.first else { return nil }
        guard values.count == 1, let data = Data(base64Encoded: String(key.dropFirst(sessionMarker.count))) else {
            throw invalid("暂存的登录状态有误。")
        }
        return data
    }

    static func acknowledgeSession(_ database: OpaquePointer, payload: Data) throws {
        try sessionSQL(database, "DELETE FROM legacy_imports WHERE key = ?", data: payload)
    }

    private static func sessionSQL(_ database: OpaquePointer, _ query: String, data: Data) throws {
        let statement = try prepare(database, query)
        defer { sqlite3_finalize(statement) }
        let key = sessionMarker + data.base64EncodedString()
        guard sqlite3_bind_text(statement, 1, key, -1, transient) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE else { throw error(database) }
    }

    private static func clearInstallRecords(_ db: OpaquePointer) throws {
        try sql(db, "DELETE FROM legacy_imports WHERE key GLOB 'legado.fullRestore.*' OR key GLOB 'legado.pendingBackupSession.*'")
    }

    static func recover(database: OpaquePointer, storage: FullBackupStorage) throws {
        try installLock.withLock { try recoverLocked(database: database, storage: storage) }
    }

    private static func recoverLocked(database: OpaquePointer, storage: FullBackupStorage) throws {
        let journal = storage.journal
        guard fm.fileExists(atPath: journal.path) else { return }
        let descriptor = journal.appendingPathComponent("install.json")
        if fm.fileExists(atPath: descriptor.path) {
            let install = try JSONDecoder().decode(Install.self, from: Data(contentsOf: descriptor))
            let key = marker + install.id.uuidString
            let committed = try !rows(database, "SELECT 1 FROM legacy_imports WHERE key='" + key + "'").isEmpty
            if !committed {
                let originalPreferences = try readPreferences(journal.appendingPathComponent(prefsFile))
                for item in install.changes {
                    guard let root = storage.roots.first(where: { $0.name == item.root }), validName(item.name),
                          isAsset(root: root.name, name: item.name, databaseName: liveFilename(database)) else {
                        throw invalid("本机恢复记录损坏。")
                    }
                    let backup = journal.appendingPathComponent(root.name).appendingPathComponent(item.name)
                    let target = root.url.appendingPathComponent(item.name)
                    let saved = fm.fileExists(atPath: backup.path)
                    guard !item.hadOriginal || saved else { continue }
                    if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                    if saved { try fm.moveItem(at: backup, to: target) }
                }
                storage.defaults.setPersistentDomain(originalPreferences, forName: storage.domain)
                guard storage.defaults.synchronize() else { throw invalid("无法还原本机偏好设置。") }
            }
            // Rename the journal before recursive deletion. A restart during deletion
            // will never interpret a partially deleted journal as a failed install.
            let discard = fm.temporaryDirectory.appendingPathComponent("legado-restore-cleanup-" + UUID().uuidString)
            try fm.moveItem(at: journal, to: discard)
            try? fm.removeItem(at: discard)
            if committed { try sql(database, "DELETE FROM legacy_imports WHERE key='" + key + "'") }
        } else {
            // No live data is touched until install.json is durably written.
            try fm.removeItem(at: journal)
        }
    }

    private static func liveFilename(_ db: OpaquePointer) -> String {
        URL(fileURLWithPath: String(cString: sqlite3_db_filename(db, "main"))).lastPathComponent
    }

    private static func withDatabase<T>(at url: URL, create: Bool, _ work: (OpaquePointer) throws -> T) throws -> T {
        var raw: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | (create ? SQLITE_OPEN_CREATE : 0)
        let status = sqlite3_open_v2(url.path, &raw, flags, nil)
        defer { if let raw { sqlite3_close(raw) } }
        guard status == SQLITE_OK, let db = raw else { throw invalid("无法打开暂存数据库。") }
        sqlite3_busy_timeout(db, 5_000)
        try sql(db, "PRAGMA trusted_schema = OFF")
        try sql(db, "PRAGMA foreign_keys = ON")
        return try work(db)
    }

    private static func copyDatabase(from source: OpaquePointer, to destination: OpaquePointer) throws {
        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else { throw error(destination) }
        let status = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard status == SQLITE_DONE, finish == SQLITE_OK else { throw error(destination) }
    }

    private static func databaseFingerprint(_ db: OpaquePointer) throws -> String {
        var hash = SHA256()
        func field(_ bytes: Data) {
            var size = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &size) { hash.update(data: Data($0)) }
            hash.update(data: bytes)
        }
        for name in try tableNames(db) {
            field(Data(name.utf8))
            var query = "SELECT * FROM " + quoted(name)
            if name == "legacy_imports" { query += " WHERE key NOT GLOB 'legado.fullRestore.*' AND key NOT GLOB 'legado.pendingBackupSession.*'" }
            let statement = try prepare(db, query + " ORDER BY rowid")
            defer { sqlite3_finalize(statement) }
            while try hasRow(db, statement) {
                try Task.checkCancellation()
                for i in 0..<sqlite3_column_count(statement) {
                    hash.update(data: Data([UInt8(sqlite3_column_type(statement, i))]))
                    if let bytes = sqlite3_column_blob(statement, i) {
                        field(Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: bytes), count: Int(sqlite3_column_bytes(statement, i)), deallocator: .none))
                    } else { field(Data()) }
                }
            }
        }
        return hex(hash.finalize())
    }

    private static func tableNames(_ db: OpaquePointer) throws -> [String] {
        try rows(db, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name").map { $0[0] }
    }

    private static func quoted(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func attach(_ url: URL, to db: OpaquePointer) throws {
        let statement = try prepare(db, "ATTACH DATABASE ? AS incoming_backup")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_text(statement, 1, url.path, -1, transient) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE else { throw error(db) }
    }

    private static func rows(_ db: OpaquePointer, _ query: String) throws -> [[String]] {
        let statement = try prepare(db, query)
        defer { sqlite3_finalize(statement) }
        var result = [[String]]()
        while try hasRow(db, statement) {
            result.append((0..<sqlite3_column_count(statement)).map { i in
                sqlite3_column_text(statement, i).map { String(cString: $0) } ?? ""
            })
        }
        return result
    }

    private static func hasRow(_ db: OpaquePointer, _ statement: OpaquePointer) throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw error(db)
        }
    }

    private static func prepare(_ db: OpaquePointer, _ query: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, let statement else { throw error(db) }
        return statement
    }

    private static func sql(_ db: OpaquePointer, _ query: String) throws {
        guard sqlite3_exec(db, query, nil, nil, nil) == SQLITE_OK else { throw error(db) }
    }

    private static func error(_ db: OpaquePointer) -> LegadoDatabaseError {
        .execute("备份数据库：" + String(cString: sqlite3_errmsg(db)))
    }
}
