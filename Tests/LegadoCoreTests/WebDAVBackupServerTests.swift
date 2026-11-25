import Foundation
import Testing
@testable import LegadoCore

@Suite(.enabled(if: ProcessInfo.processInfo.environment["LEGADO_TEST_DAV_PORT"] != nil))
struct WebDAVBackupServerTests {
    private var server: String {
        get throws {
            let port = try #require(ProcessInfo.processInfo.environment["LEGADO_TEST_DAV_PORT"].flatMap(UInt16.init))
            return "http://127.0.0.1:\(port)"
        }
    }

    @Test
    func roundTripsVersionedFilesInNewNestedDirectory() async throws {
        let client = try WebDAVSync(directoryURL: "\(server)/dav/新目录/my%20books/\(UUID())",
                                    username: "", password: "")
        let files = FileManager.default
        let folder = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: folder) }
        let local = folder.appendingPathComponent("backup.zip")
        let head = Data([0x50, 0x4b, 0x03, 0x04])
        let firstData = head + Data(repeating: 0x61, count: 1_500_000)
        let secondData = head + Data(repeating: 0x62, count: 3_000_000)
        try firstData.write(to: local)
        let first = try await step("upload first ZIP, \(firstData.count) bytes") { try await client.uploadBackup(from: local) }
        let legacy = Data(#"{"version":1,"books":[]}"#.utf8)
        try await step("upload legacy JSON") { try await client.upload(legacy, replacing: nil) }
        try secondData.write(to: local)
        let second = try await step("upload second ZIP, \(secondData.count) bytes") { try await client.uploadBackup(from: local) }

        let list = try await step("list backups") { try await client.listBackups() }
        let archives = list.filter { !$0.isLegacySnapshot }
        #expect(archives.map(\.name) == [second.name, first.name])
        #expect(archives.map(\.size) == [Int64(secondData.count), Int64(firstData.count)])
        let legacyFile = try #require(list.first { $0.isLegacySnapshot })
        for (file, content) in zip(archives + [legacyFile], [secondData, firstData, legacy]) {
            let downloaded = folder.appendingPathComponent(file.name)
            try await step("download \(file.name), expected \(content.count) bytes") {
                try await client.downloadBackup(file, to: downloaded)
            }
            let received = try Data(contentsOf: downloaded)
            #expect(received == content)
        }
    }

    @Test func verifiesCredentialsAndCreatesTheConfiguredDirectory() async throws {
        for (user, password) in [("", ""), ("reader", "incorrect")] {
            let reject = try WebDAVSync(directoryURL: "\(server)/private", username: user, password: password)
            await #expect(throws: WebDAVSyncError.httpStatus(method: "PROPFIND", path: "/private", code: 401)) {
                try await reject.checkConnection()
            }
        }

        let path = "/private/\(UUID())/backups"
        let client = try WebDAVSync(directoryURL: "\(server)\(path)", username: "reader", password: "test")
        await #expect(throws: WebDAVSyncError.httpStatus(method: "PROPFIND", path: path, code: 404)) {
            try await client.checkConnection()
        }
        try await client.createBackupDirectory()
        try await client.checkConnection()
        try await client.createBackupDirectory()
        let methods = Set(try await client.allowedMethods())
        #expect(methods.isSuperset(of: ["OPTIONS", "PROPFIND", "HEAD", "GET", "COPY", "MOVE", "DELETE"]))
        #expect(try await client.listBackups(includeOtherArchives: true).isEmpty)
    }

    @Test func copiesMovesAndDeletesOnlyTheSelectedArchives() async throws {
        let client = try WebDAVSync(directoryURL: "\(server)/private/\(UUID())/我的 备份",
                                    username: "reader", password: "test")
        try await client.createBackupDirectory()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // Two valid empty ZIP archives, with different end-of-central-directory comments.
        let emptyZIP = Data([0x50, 0x4b, 0x05, 0x06]) + Data(repeating: 0, count: 16)
        let content = emptyZIP + Data([1, 0, 65])
        let keepContent = emptyZIP + Data([2, 0, 66, 67])
        let local = folder.appendingPathComponent("input.zip")
        try content.write(to: local)
        let source = try await client.uploadBackup(from: local)
        try keepContent.write(to: local)
        let keep = try await client.uploadBackup(from: local)
        try await client.checkConnection()
        #expect(try await client.backupSize(source) == Int64(content.count))

        let copyName = "中文副本 #1.zip"
        try await client.copyBackup(source, to: copyName)
        let afterCopy = try await client.listBackups(includeOtherArchives: true)
        #expect(Set(afterCopy.map(\.name)) == [source.name, keep.name, copyName])
        let copy = try #require(afterCopy.first { $0.name == copyName })

        let directory = client.fileURL.deletingLastPathComponent()
        let copyPath = directory.appendingPathComponent(copy.name).path
        await #expect(throws: WebDAVSyncError.httpStatus(method: "COPY", path: copyPath, code: 412)) {
            try await client.copyBackup(copy, to: keep.name)
        }
        await #expect(throws: WebDAVSyncError.httpStatus(method: "MOVE", path: copyPath, code: 412)) {
            try await client.moveBackup(copy, to: keep.name)
        }
        let moveName = "归档 100%.zip"
        try await client.moveBackup(copy, to: moveName)
        let afterMove = try await client.listBackups(includeOtherArchives: true)
        #expect(Set(afterMove.map(\.name)) == [source.name, keep.name, moveName])
        let moved = try #require(afterMove.first { $0.name == moveName })
        for (file, bytes) in [(source, content), (moved, content), (keep, keepContent)] {
            let downloaded = folder.appendingPathComponent(file.name)
            try await client.downloadBackup(file, to: downloaded)
            #expect(try Data(contentsOf: downloaded) == bytes)
        }
        try await client.deleteBackup(moved)
        let remaining = try await client.listBackups(includeOtherArchives: true)
        #expect(Set(remaining.map(\.name)) == [source.name, keep.name])
        let deletedPath = directory.appendingPathComponent(moveName).path
        await #expect(throws: WebDAVSyncError.httpStatus(method: "HEAD", path: deletedPath, code: 404)) {
            _ = try await client.backupSize(moved)
        }
        try await client.deleteBackup(source)
        try await client.deleteBackup(keep)
    }

    private func step<T>(_ name: String, operation: () async throws -> T) async throws -> T {
        do { return try await operation() }
        catch { throw TransferFailure(description: "\(name): \(error)") }
    }

    private struct TransferFailure: Error, CustomStringConvertible {
        let description: String
    }
}
