import Foundation
import SwiftUI

struct BackupSyncConflict {
    fileprivate let accountKey: String
    fileprivate let localFingerprint: String
    fileprivate let remote: WebDAVBackupFile?
    var canRestoreRemote: Bool { remote != nil }
    var remoteName: String { remote?.name ?? "已移除的备份" }
}

struct LocalBackupFile: Identifiable, Sendable {
    let url: URL
    let date: Date
    let size: Int64?
    var name: String { url.lastPathComponent }
    var id: URL { url }
}

enum BackupSyncOutcome {
    case uploaded, restored, unchanged, conflict(BackupSyncConflict), legacyAvailable(WebDAVBackupFile)
}

enum BackupServiceError: LocalizedError {
    case busy, noAccount, changed, pendingSession
    var errorDescription: String? {
        switch self {
        case .busy: "另一个备份或恢复操作正在进行，请稍后重试。"
        case .noAccount: "请先保存 WebDAV 连接。"
        case .pendingSession: "书架和文件已恢复。连接和登录状态会在下次解锁并打开应用时继续恢复。"
        case .changed: "本机或远端备份已更改，请重新同步。"
        }
    }
}

@MainActor
final class WebDAVBackupService: ObservableObject {
    static let shared = WebDAVBackupService()
    @Published private(set) var isRestoring = false
    var canRestore: () -> Bool = { true }
    var stableFileRevision: () -> Int? = { 0 }
    var didRestore: () async -> Void = {}
    private var busy = false

    private struct Snapshot {
        var url: URL
        var fingerprint: String
    }

    // The local fingerprint can differ after restoring the same backup to a new
    // sandbox. Store both ends of the last successful synchronization.
    private struct Baseline: Codable {
        let local: String
        let remote: String
    }

    private func exclusively<T>(_ operation: @MainActor () async throws -> T) async throws -> T {
        guard !busy else { throw BackupServiceError.busy }
        busy = true
        defer { busy = false }
        return try await operation()
    }

    private static func temporaryZIP() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(WebDAVSync.newBackupName())
    }

    private func finishPendingSession(_ database: LegadoDatabase) async throws {
        guard let saved = try await database.pendingBackupSession() else { return }
        let session = try BackupSessionState.decode(saved)
        try session.applyAccount()
        await session.applyCookies()
        try await database.acknowledgeBackupSession(saved)
    }

    func resumeAfterInterruption(database: LegadoDatabase) async throws {
        try await exclusively { try await finishPendingSession(database) }
    }

    private func snapshot(_ database: LegadoDatabase) async throws -> Snapshot {
        guard let revision = stableFileRevision() else { throw LibraryRestoreError.busy }
        try await finishPendingSession(database)
        let file = Self.temporaryZIP()
        do {
            try await ChapterContentCache.live().prepareForBackup()
            let sessions = try await BackupSessionState.capture()
            let fingerprint = try await database.createFullBackup(at: file, connection: sessions)
            // A file rename/removal and its shelf update span two stores. An automatic
            // backup racing that operation must retry with the matching book identifiers.
            guard stableFileRevision() == revision else { throw LibraryRestoreError.busy }
            return Snapshot(url: file, fingerprint: fingerprint)
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    func createArchive(database: LegadoDatabase) async throws -> URL {
        try await exclusively { try await snapshot(database).url }
    }

    private func install(_ archive: URL, database: LegadoDatabase) async throws {
        guard canRestore() else { throw LibraryRestoreError.busy }
        isRestoring = true
        defer { isRestoring = false }
        let data = try await Task.detached { try LegadoDatabase.fullBackupConnection(at: archive) }.value
        _ = try BackupSessionState.decode(data)
        try await database.restoreFullBackup(from: archive)
        // The database transaction also records the sessions to install. A process
        // termination or locked Keychain can resume this step without reimporting.
        var sessionPending = false
        do { try await finishPendingSession(database) } catch { sessionPending = true }
        await ChapterContentCache.live().resetAfterRestore()
        DiagnosticLog.shared.reloadAfterRestore()
        await didRestore()
        WebDAVBackupScheduler.shared.reloadSettings()
        if sessionPending { throw BackupServiceError.pendingSession }
    }

    func restore(from archive: URL, database: LegadoDatabase) async throws {
        try await exclusively { try await install(archive, database: database) }
    }

    private func accountKey(_ client: WebDAVSync, _ account: WebDAVAccount) -> String {
        "webdav.fullSync." + WebDAVSync.fingerprint(Data((client.fileURL.absoluteString + "\n" + account.username).utf8))
    }

    private func baseline(_ key: String) -> Baseline? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(Baseline.self, from: $0) }
    }

    private func record(_ local: String, _ remote: WebDAVBackupFile, key: String) throws {
        let data = try JSONEncoder().encode(Baseline(local: local, remote: remote.name))
        UserDefaults.standard.set(data, forKey: key)
    }

    private func latest(_ client: WebDAVSync) async throws -> WebDAVBackupFile? {
        try await client.listBackups().first { !$0.isLegacySnapshot }
    }

    func sync(database: LegadoDatabase, account: WebDAVAccount) async throws -> BackupSyncOutcome {
        try await exclusively { try await synchronize(database, account: account, resolution: nil) }
    }

    func resolve(_ conflict: BackupSyncConflict, preferLocal: Bool,
                 database: LegadoDatabase, account: WebDAVAccount) async throws -> BackupSyncOutcome {
        try await exclusively {
            try await synchronize(database, account: account, resolution: (conflict, preferLocal))
        }
    }

    private func synchronize(_ database: LegadoDatabase, account: WebDAVAccount,
                             resolution: (BackupSyncConflict, Bool)?) async throws -> BackupSyncOutcome {
        let client = try account.makeClient()
        let key = accountKey(client, account)
        let local = try await snapshot(database)
        defer { try? FileManager.default.removeItem(at: local.url) }
        let files = try await client.listBackups()
        let remote = files.first { !$0.isLegacySnapshot }
        let base = baseline(key)
        let conflict = BackupSyncConflict(accountKey: key, localFingerprint: local.fingerprint, remote: remote)
        if let (previous, preferLocal) = resolution {
            guard previous.accountKey == key, previous.localFingerprint == local.fingerprint,
                  previous.remote == remote else { throw BackupServiceError.changed }
            if preferLocal { return try await upload(local, to: client, key: key) }
            guard let remote else { throw BackupServiceError.changed }
            return try await download(remote, from: client, key: key, database: database, expected: local.fingerprint)
        }
        guard let remote else {
            if base != nil { return .conflict(conflict) }
            if let legacy = files.first(where: { $0.isLegacySnapshot }) { return .legacyAvailable(legacy) }
            return try await upload(local, to: client, key: key)
        }
        if base?.remote == remote.name {
            if base?.local == local.fingerprint { return .unchanged }
            return try await upload(local, to: client, key: key)
        }
        if base?.local == local.fingerprint {
            return try await download(remote, from: client, key: key, database: database, expected: local.fingerprint)
        }
        return .conflict(conflict)
    }

    func startZIPHistory(database: LegadoDatabase, account: WebDAVAccount,
                         legacy: WebDAVBackupFile) async throws -> BackupSyncOutcome {
        try await exclusively {
            let client = try account.makeClient()
            let local = try await snapshot(database)
            defer { try? FileManager.default.removeItem(at: local.url) }
            let files = try await client.listBackups()
            guard legacy.isLegacySnapshot, files == [legacy] else { throw BackupServiceError.changed }
            return try await upload(local, to: client, key: accountKey(client, account))
        }
    }

    private func upload(_ local: Snapshot, to client: WebDAVSync, key: String) async throws -> BackupSyncOutcome {
        let remote = try await client.uploadBackup(from: local.url)
        try record(local.fingerprint, remote, key: key)
        return .uploaded
    }

    private func download(_ remote: WebDAVBackupFile, from client: WebDAVSync, key: String,
                          database: LegadoDatabase, expected: String?) async throws -> BackupSyncOutcome {
        let file = Self.temporaryZIP()
        defer { try? FileManager.default.removeItem(at: file) }
        try await client.downloadBackup(remote, to: file)
        if let expected {
            let current = try await snapshot(database)
            defer { try? FileManager.default.removeItem(at: current.url) }
            guard current.fingerprint == expected, try await latest(client) == remote else { throw BackupServiceError.changed }
        }
        try await install(file, database: database)
        // A completed restore must remain a success even if disk space no longer
        // permits an additional temporary archive for the synchronization baseline.
        UserDefaults.standard.removeObject(forKey: key)
        // A historical restore is an explicit local choice. Ask before the next
        // sync would replace it with a newer version from the same directory.
        if expected == nil, (try? await latest(client))?.name != remote.name { return .restored }
        if let restored = try? await snapshot(database) {
            defer { try? FileManager.default.removeItem(at: restored.url) }
            try record(restored.fingerprint, remote, key: key)
        }
        return .restored
    }

    func restoreRemote(_ backup: WebDAVBackupFile, database: LegadoDatabase, account: WebDAVAccount) async throws {
        try await exclusively {
            let client = try account.makeClient()
            _ = try await download(backup, from: client, key: accountKey(client, account), database: database, expected: nil)
        }
    }

    nonisolated static func localBackupDirectory() throws -> URL {
        let files = FileManager.default
        let documents = try files.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = documents.appendingPathComponent("Backups", isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func backUpLocally(database: LegadoDatabase) async throws -> URL {
        try await exclusively {
            let targetDirectory = try Self.localBackupDirectory()
            let archive = try await snapshot(database).url
            defer { try? FileManager.default.removeItem(at: archive) }
            let saved = targetDirectory.appendingPathComponent(archive.lastPathComponent)
            try Task.checkCancellation()
            // Both folders belong to the same app container. Publish only the finished ZIP.
            try FileManager.default.moveItem(at: archive, to: saved)
            return saved
        }
    }

    nonisolated static func localBackups() async throws -> [LocalBackupFile] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]
        let directory = try localBackupDirectory()
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys),
                                                               options: .skipsHiddenFiles)
        var backups = [LocalBackupFile]()
        for url in urls where url.pathExtension.lowercased() == "zip" {
            let metadata = try url.resourceValues(forKeys: keys)
            guard metadata.isRegularFile == true, metadata.isSymbolicLink != true else { continue }
            backups.append(LocalBackupFile(url: url, date: metadata.contentModificationDate ?? .distantPast,
                                          size: metadata.fileSize.map(Int64.init)))
        }
        return backups.sorted { $0.date == $1.date ? $0.name > $1.name : $0.date > $1.date }
    }

    nonisolated static func saveLocal(_ archive: URL, directory: URL) throws {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let partial = directory.appendingPathComponent(".\(UUID().uuidString).partial")
        defer { try? files.removeItem(at: partial) }
        try files.copyItem(at: archive, to: partial)
        try Task.checkCancellation()
        try files.moveItem(at: partial, to: directory.appendingPathComponent(archive.lastPathComponent))
    }

    func automaticBackup(database: LegadoDatabase, destinations: Set<BackupDestination>,
                         didSave: @MainActor (BackupDestination) -> Void) async throws {
        try await exclusively {
            let local = try await snapshot(database)
            defer { try? FileManager.default.removeItem(at: local.url) }
            var firstError: Error?
            if destinations.contains(.local) {
                do {
                    try await Task.detached(priority: .utility) {
                        try Self.saveLocal(local.url, directory: Self.localBackupDirectory())
                    }.value
                    didSave(.local)
                } catch { firstError = error }
            }
            if destinations.contains(.webDAV) {
                do {
                    try Task.checkCancellation()
                    guard let account = try WebDAVAccount.load() else { throw BackupServiceError.noAccount }
                    let client = try account.makeClient()
                    _ = try await upload(local, to: client, key: accountKey(client, account))
                    didSave(.webDAV)
                } catch { if firstError == nil { firstError = error } }
            }
            if let firstError { throw firstError }
        }
    }
}
