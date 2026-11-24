import Foundation
import Testing
@testable import LegadoCore

struct WebDAVBackupServerTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LEGADO_TEST_DAV_PORT"] != nil))
    func roundTripsVersionedFilesInNewNestedDirectory() async throws {
        let port = try #require(ProcessInfo.processInfo.environment["LEGADO_TEST_DAV_PORT"].flatMap(UInt16.init))
        let client = try WebDAVSync(directoryURL: "http://127.0.0.1:\(port)/dav/新目录/my%20books/\(UUID())",
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

    private func step<T>(_ name: String, operation: () async throws -> T) async throws -> T {
        do { return try await operation() }
        catch { throw TransferFailure(description: "\(name): \(error)") }
    }

    private struct TransferFailure: Error, CustomStringConvertible {
        let description: String
    }
}
