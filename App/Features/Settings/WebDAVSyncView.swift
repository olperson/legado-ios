import Security
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct WebDAVSyncView: View {
    @EnvironmentObject private var books: BookLibraryModel
    @EnvironmentObject private var sources: SourceLibraryModel
    @EnvironmentObject private var activity: ReadingActivityModel
    @State private var account = WebDAVAccount()
    @State private var busy = false
    @State private var message: String?
    @State private var picksFile = false
    @State private var review: Review?

    private struct Round {
        let client: WebDAVSync
        let baseKey: String
        let remote: WebDAVRemoteSnapshot?
    }

    private struct Review {
        let local: Data
        let incoming: Data?
        let localSummary: String
        let incomingSummary: String
        let name: String
        let round: Round?
    }

    private typealias SnapshotInfo = (data: Data, summary: WebDAVSnapshotSummary)

    var body: some View {
        Form {
            Section {
                TextField("WebDAV 目录地址", text: Binding(get: { account.directory }, set: {
                    account.directory = $0
                    account.password = ""
                }))
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                TextField("用户名", text: Binding(get: { account.username }, set: {
                    account.username = $0
                    account.password = ""
                }))
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                SecureField("密码或应用专用密码", text: $account.password)
                    .textContentType(.password)
                Button("立即同步") { perform { try await synchronize() } }
                    .disabled(account.directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("WebDAV 服务器")
            } footer: {
                Text("填写已有目录的地址。设备通过目录中的 legado-sync.json 同步在线书架、阅读进度、书架分组、书源和书签。本地 TXT、EPUB 和正文缓存保存在各自设备上。")
            }
            .disabled(busy || review != nil)

            Section {
                Button("选择 JSON 文件导入") { picksFile = true }
                    .disabled(busy || review != nil)
            } header: { Text("从同步文件恢复") } footer: {
                Text("选择小浣熊阅读的同步 JSON，核对内容后可恢复到本机。")
            }

            if let review {
                Section {
                    Text("本机：\(review.localSummary)")
                    Text("\(review.name)：\(review.incomingSummary)")
                    if review.incoming != nil {
                        Button(review.round == nil ? "确认用文件替换本机同步内容" : "采用远端，替换本机同步内容", role: .destructive) {
                            resolve(review, upload: false)
                        }
                    }
                    if review.round != nil {
                        Button("采用本机，写入远端文件", role: .destructive) {
                            resolve(review, upload: true)
                        }
                    }
                    Button("取消", role: .cancel) { self.review = nil }
                } header: {
                    Text(review.round == nil ? "确认导入" : "同步冲突")
                } footer: {
                    Text("所选版本将替换另一端同步范围内的数据。")
                }
                .disabled(busy)
            }
            if busy { ProgressView("正在处理…") }
            if let message { Text(message).accessibilityLabel("操作结果：\(message)") }
        }
        .navigationTitle("WebDAV 同步")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            do { if let saved = try WebDAVAccount.load() { account = saved } }
            catch { message = error.localizedDescription }
        }
        .fileImporter(isPresented: $picksFile, allowedContentTypes: [.json]) { result in
            do {
                let file = SourceImportFile(url: try result.get())
                perform { try await previewFile(file) }
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError {
                return
            } catch { message = error.localizedDescription }
        }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        message = nil
        Task {
            defer { busy = false }
            do { try await action() }
            catch { message = error.localizedDescription }
        }
    }

    private func database() throws -> LegadoDatabase {
        guard let database = books.syncDatabase else { throw LibraryRestoreError.unavailable }
        guard books.canRestoreSnapshot, sources.canRestoreSnapshot, activity.canRestoreSnapshot else { throw LibraryRestoreError.busy }
        return database
    }

    private func synchronize() async throws {
        let database = try database()
        let client = try WebDAVSync(directoryURL: account.directory, username: account.username, password: account.password)
        let identity = client.fileURL.absoluteString + "\n" + account.username
        let key = "webdav.base." + WebDAVSync.fingerprint(Data(identity.utf8))
        let local = try await database.exportWebDAVSnapshot()
        let remote = try await client.fetch()
        let base = UserDefaults.standard.string(forKey: key)
        let (direction, localSummary, incoming) = try await Self.compare(local: local, remote: remote, base: base)
        try account.save()
        let round = Round(client: client, baseKey: key, remote: remote)
        switch direction {
        case .conflict:
            review = Review(local: local, incoming: incoming?.data, localSummary: counts(localSummary),
                            incomingSummary: incoming.map { counts($0.summary) } ?? "文件已移除",
                            name: "远端", round: round)
        case .upload:
            try await upload(local, round: round)
        case .download:
            guard let incoming else { throw SyncViewError("远端同步文件已移除，请重新同步。") }
            try await restore(incoming.data, expected: local)
            recordBase(incoming.data, round: round)
            message = "已从 WebDAV 恢复。"
        case .unchanged:
            recordBase(local, round: round)
            message = "本机与远端已同步。"
        }
    }

    private nonisolated static func compare(local: Data, remote: WebDAVRemoteSnapshot?, base: String?) async throws
        -> (WebDAVSyncDirection, WebDAVSnapshotSummary, SnapshotInfo?) {
        let localSummary = try LegadoDatabase.webDAVSnapshotSummary(local)
        let incoming = try remote.map { try LegadoDatabase.inspectWebDAVSnapshot($0.data) }
        let direction = WebDAVSync.direction(local: local, localIsEmpty: localSummary.isEmpty,
                                             remoteData: incoming?.data, remoteIsEmpty: incoming?.summary.isEmpty == true,
                                             base: base)
        return (direction, localSummary, incoming)
    }

    private func previewFile(_ file: SourceImportFile) async throws {
        let database = try database()
        let local = try await database.exportWebDAVSnapshot()
        let (incoming, localSummary) = try await Task.detached(priority: .userInitiated) {
            (try LegadoDatabase.inspectWebDAVSnapshot(file.read()), try LegadoDatabase.webDAVSnapshotSummary(local))
        }.value
        review = Review(local: local, incoming: incoming.data, localSummary: counts(localSummary),
                        incomingSummary: counts(incoming.summary),
                        name: file.url.lastPathComponent, round: nil)
    }

    private func resolve(_ selected: Review, upload useLocal: Bool) {
        review = nil
        perform {
            if let round = selected.round { try await round.client.verifyUnchanged(round.remote) }
            if useLocal, let round = selected.round {
                try await upload(selected.local, round: round)
            } else if let incoming = selected.incoming {
                try await restore(incoming, expected: selected.local)
                if let round = selected.round { recordBase(incoming, round: round) }
                message = selected.round == nil ? "已从文件恢复。" : "已从 WebDAV 恢复。"
            }
        }
    }

    private func upload(_ local: Data, round: Round) async throws {
        let database = try database()
        guard try await database.exportWebDAVSnapshot() == local else {
            throw SyncViewError("本机内容已更改，请重新同步。")
        }
        try await round.client.upload(local, replacing: round.remote)
        recordBase(local, round: round)
        message = "已上传到 WebDAV。"
    }

    private func restore(_ data: Data, expected: Data) async throws {
        try await books.restoreWebDAVSnapshot(data, expected: expected, sources: sources, activity: activity)
    }

    private func recordBase(_ data: Data, round: Round) {
        UserDefaults.standard.set(WebDAVSync.fingerprint(data), forKey: round.baseKey)
    }

    private func counts(_ value: WebDAVSnapshotSummary) -> String {
        "\(value.bookCount) 本书、\(value.groupCount) 个分组、\(value.sourceCount) 个书源、\(value.bookmarkCount) 个书签"
    }
}

private struct SyncViewError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

private struct WebDAVAccount: Codable {
    var directory = ""
    var username = ""
    var password = ""

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "legado.webdav",
         kSecAttrAccount as String: "connection"]
    }

    static func load() throws -> Self? {
        var query = Self.query
        query[kSecReturnData as String] = true
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = value as? Data else { throw SyncViewError("无法读取已保存的 WebDAV 连接。") }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    func save() throws {
        let data = try JSONEncoder().encode(self)
        let changes = [kSecValueData as String: data]
        let updated = SecItemUpdate(Self.query as CFDictionary, changes as CFDictionary)
        if updated == errSecItemNotFound {
            var item = Self.query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            try Self.check(SecItemAdd(item as CFDictionary, nil))
        } else {
            try Self.check(updated)
        }
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw SyncViewError("无法访问本机钥匙串（\(status)）。")
        }
    }
}
