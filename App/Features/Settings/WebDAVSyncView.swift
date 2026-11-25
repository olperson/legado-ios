import Security
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct WebDAVSyncView: View {
    @EnvironmentObject private var books: BookLibraryModel
    @EnvironmentObject private var sources: SourceLibraryModel
    @EnvironmentObject private var activity: ReadingActivityModel

    @State private var account = WebDAVAccount()
    @State private var loadedAccount = false
    @State private var work: String?
    @State private var message: String?
    @State private var lastLocalBackup: URL?
    @State private var sheet: BackupSheet?
    @State private var sheetHasDismissed = true
    @State private var selection: Selection?
    @State private var importCopy: Task<TemporaryBackup, Error>?
    @State private var review: Review?

    private enum BackupSheet: Identifiable {
        case local([LocalBackupFile]), remote([WebDAVBackupFile], WebDAVSync), file

        var id: String {
            switch self {
            case .local: "local"
            case .remote: "remote"
            case .file: "file"
            }
        }
    }

    private enum Selection {
        case backup(Review), file(SourceImportFile)
    }

    private enum Review {
        case local(TemporaryBackup)
        case onDevice(LocalBackupFile)
        case remote(WebDAVBackupFile, isLatest: Bool)
        case conflict(BackupSyncConflict)
        case legacy(WebDAVBackupFile)

        var title: String {
            switch self {
            case .local, .onDevice, .remote: "恢复所选备份？"
            case .conflict: "选择要保留的版本"
            case .legacy: "发现旧版同步文件"
            }
        }

        var detail: String {
            switch self {
            case .local(let file):
                "“\(file.name)”中的数据和设置将替换本机内容。"
            case .onDevice(let file):
                "“\(file.name)”中的数据和设置将替换本机内容。"
            case .remote(let file, _) where file.isLegacySnapshot:
                "这是旧版同步文件。仅恢复在线书架、分组、进度、书源和书签，并替换本机对应的数据。"
            case .remote(let file, _):
                "“\(file.name)”中的数据和设置将替换本机内容。"
            case .conflict(let conflict) where conflict.remote == nil:
                "上次同步的云端备份已移除。可以重新上传本机内容，创建一份新备份。"
            case .legacy:
                "可以先用旧版文件恢复在线书架、分组、进度、书源和书签，再创建完整 ZIP。也可以直接备份当前本机数据。旧版文件将继续保留。"
            case .conflict(let conflict):
                "本机与云端备份“\(conflict.remoteName)”存在差异。保留本机会上传一个新备份。恢复云端会替换本机数据和设置。"
            }
        }
    }

    var body: some View {
        Form {
            connectionSection
            localSection
            WebDAVAutoBackupSection()
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let work {
                HStack {
                    ProgressView()
                    Text(work)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal).padding(.vertical, 8)
                .background(.bar)
            } else if let message {
                Text(message)
                    .accessibilityIdentifier("backup.status")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal).padding(.vertical, 8)
                    .background(.bar)
            }
        }
        .navigationTitle("备份与恢复")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loadedAccount else { return }
            loadedAccount = true
            do { account = try WebDAVAccount.load() ?? WebDAVAccount() }
            catch { message = error.localizedDescription }
        }
        .onDisappear { importCopy?.cancel() }
        .sheet(item: $sheet, onDismiss: {
            sheetHasDismissed = true
            handleSelectionWhenReady()
        }) { presented in
            switch presented {
            case .file:
                ReadingImportPicker.backup(directoryURL: try? WebDAVBackupService.localBackupDirectory()) { file in
                    select(.file(file))
                } onCancel: {
                    select(nil)
                }
            case .local(let files):
                localHistoryView(files)
            case .remote(let files, let client):
                RemoteBackupHistoryView(files: files, client: client, onCancel: { select(nil) }) { file, isLatest in
                    select(.backup(.remote(file, isLatest: isLatest)))
                }
            }
        }
        .alert(review?.title ?? "恢复备份", isPresented: Binding(
            get: { review != nil }, set: { if !$0 { review = nil } }
        ), presenting: review) { selected in
            switch selected {
            case .conflict(let conflict):
                Button("保留本机并上传") { uploadLocal() }
                if let remote = conflict.remote {
                    Button("恢复云端版本", role: .destructive) { restore(.remote(remote, isLatest: true)) }
                }
            case .legacy(let file):
                Button("恢复旧版数据并备份为 ZIP", role: .destructive) { migrate(file, restoreFirst: true) }
                Button("从本机开始 ZIP 备份") { migrate(file, restoreFirst: false) }
            case .local, .onDevice, .remote:
                Button("恢复备份", role: .destructive) { restore(selected) }
            }
            Button("取消", role: .cancel) {}
        } message: { selected in
            Text(selected.detail)
        }
    }

    private var connectionSection: some View {
        Section {
            HStack {
                TextField("WebDAV 目录地址", text: $account.directory)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                Menu {
                    ForEach(WebDAVAddress.Preset.allCases, id: \.self) { preset in
                        Button(preset.title) {
                            do {
                                try account.apply(preset)
                                message = nil
                            } catch { message = error.localizedDescription }
                        }
                    }
                } label: {
                    Label("地址模板", systemImage: "list.bullet")
                        .labelStyle(.iconOnly)
                }
                .accessibilityIdentifier("backup.address.templates")
                .buttonStyle(.borderless)
            }
            TextField("用户名", text: $account.username)
            .textContentType(.username)
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
            SecureField("密码或应用专用密码", text: $account.password)
                .textContentType(.password)
            Group {
                Button("保存连接") {
                    do {
                        try saveConnection()
                        message = "WebDAV 连接已保存。"
                    } catch { message = error.localizedDescription }
                }
                Button("立即同步") {
                    perform("正在同步…") {
                        try saveConnection()
                        let result = try await WebDAVBackupService.shared.sync(database: database(), account: account)
                        try didSynchronize(result)
                    }
                }
                Button("从 WebDAV 选择备份恢复") { openRemoteHistory() }
                Menu("连接工具") {
                    Button("测试连接") {
                        perform("正在连接目录…") {
                            try await connectionClient().checkConnection()
                            message = "已连接到 WebDAV 目录。"
                        }
                    }
                    Button("查看服务器支持的方法") {
                        perform("正在查询服务器方法…") {
                            let methods = try await connectionClient().allowedMethods()
                            message = methods.isEmpty ? "服务器没有在 OPTIONS 响应中列出方法。"
                                : "服务器声明支持：" + methods.joined(separator: "、")
                        }
                    }
                    Button("创建此备份目录") {
                        perform("正在创建备份目录…") {
                            try await connectionClient().createBackupDirectory()
                            message = "备份目录已就绪。"
                        }
                    }
                }
                .accessibilityIdentifier("backup.connection.tools")
            }
            .disabled(account.directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } header: {
            Text("WebDAV 服务器")
        } footer: {
            Text("可直接输入主机名，或从地址模板选择服务。已有备份时请填写原目录。")
        }
        .disabled(work != nil)
    }

    private var localSection: some View {
        Section {
            Button("备份到本机") {
                perform("正在备份到本机…") {
                    lastLocalBackup = nil
                    lastLocalBackup = try await WebDAVBackupService.shared.backUpLocally(database: database())
                }
            }
            .accessibilityValue(lastLocalBackup?.lastPathComponent ?? "")
            if let lastLocalBackup {
                Text("已备份到本机：\(lastLocalBackup.lastPathComponent)").font(.footnote)
            }
            Button("从本机选择备份恢复") {
                perform("正在读取本机备份…") {
                    let files = try await WebDAVBackupService.localBackups()
                    present(.local(files))
                }
            }
            Button("选择 ZIP 文件恢复") { present(.file) }
        } header: {
            Text("本地备份")
        } footer: {
            Text("本机备份保存在「文件」中本应用的 Backups 文件夹。ZIP 包含书籍、设置和已保存的账户密码，请妥善保管。卸载前请将备份另存到应用外。")
        }
        .disabled(work != nil)
    }

    private func present(_ next: BackupSheet) {
        selection = nil
        sheetHasDismissed = false
        sheet = next
    }

    private func select(_ next: Selection?) {
        selection = next
        sheet = nil
        handleSelectionWhenReady()
    }

    // The system picker can deliver its URL just before or just after dismissing.
    private func handleSelectionWhenReady() {
        guard sheetHasDismissed, let selected = selection else { return }
        selection = nil
        switch selected {
        case .backup(let chosen):
            review = chosen
        case .file(let file):
            perform("正在读取 ZIP…") {
                let task = Task.detached(priority: .userInitiated) { try TemporaryBackup.importCopy(of: file) }
                importCopy = task
                defer { importCopy = nil }
                let copy = try await task.value
                if !task.isCancelled { review = .local(copy) }
            }
        }
    }

    private func openRemoteHistory() {
        perform("正在读取备份列表…") {
            let client = try savedClient()
            let files = try await client.listBackups(includeOtherArchives: true)
            present(.remote(files, client))
        }
    }

    private func localHistoryView(_ files: [LocalBackupFile]) -> some View {
        ReadingNavigationStack {
            List {
                if files.isEmpty { Text("本机还没有备份。").foregroundStyle(.secondary) }
                ForEach(files) { file in
                    Button { select(.backup(.onDevice(file))) } label: {
                        BackupHistoryLabel(name: file.name, date: file.date, size: file.size)
                    }
                    .accessibilityLabel(file.name)
                    .accessibilityValue(file.date.formatted(date: .abbreviated, time: .standard))
                    .accessibilityIdentifier("backup.local." + file.name)
                }
            }
            .navigationTitle("本机备份")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { select(nil) }
                }
            }
        }
    }

    private func perform(_ description: String, _ action: @escaping @MainActor () async throws -> Void) {
        guard work == nil else { return }
        work = description
        message = nil
        Task {
            defer { work = nil }
            do { try await action() }
            catch is CancellationError {}
            catch { message = error.localizedDescription }
        }
    }

    private func database() throws -> LegadoDatabase {
        guard let database = books.syncDatabase else { throw LibraryRestoreError.unavailable }
        return database
    }

    private func connectionClient() throws -> WebDAVSync {
        try account.completeDirectory()
        return try account.makeClient()
    }

    private func saveConnection() throws {
        try account.completeDirectory()
        try account.save()
    }

    private func savedClient() throws -> WebDAVSync {
        try saveConnection()
        return try account.makeClient()
    }

    private func uploadLocal() {
        perform("正在上传备份…") {
            let result = try await WebDAVBackupService.shared.backUpToWebDAV(database: database(), account: account)
            try didSynchronize(result)
        }
    }

    private func didSynchronize(_ result: BackupSyncOutcome) throws {
        switch result {
        case .uploaded(let file):
            message = "已上传备份：\(file.name)"
        case .restored:
            try didRestore()
        case .unchanged:
            message = "本机与云端已同步。"
        case .conflict(let conflict):
            review = .conflict(conflict)
        case .legacyAvailable(let file):
            review = .legacy(file)
        }
    }

    private func migrate(_ file: WebDAVBackupFile, restoreFirst: Bool) {
        perform("正在迁移旧版备份…") {
            let db = try database()
            if restoreFirst { try await restoreLegacy(file, database: db) }
            do {
                let result = try await WebDAVBackupService.shared.backUpToWebDAV(database: db, account: account)
                try didSynchronize(result)
            } catch where restoreFirst {
                message = "已恢复旧版数据。创建 ZIP 备份失败：\(error.localizedDescription)"
            }
        }
    }

    private func restoreLegacy(_ file: WebDAVBackupFile, database: LegadoDatabase) async throws {
        let local = try await database.exportWebDAVSnapshot()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try await savedClient().downloadBackup(file, to: url)
        let data = try await Task.detached(priority: .userInitiated) {
            try LegadoDatabase.inspectWebDAVSnapshot(Data(contentsOf: url)).data
        }.value
        try await books.restoreWebDAVSnapshot(data, expected: local, sources: sources, activity: activity)
    }

    private func restore(_ selected: Review) {
        perform("正在恢复备份…") {
            let db = try database()
            switch selected {
            case .local(let file):
                try await WebDAVBackupService.shared.restore(from: file.url, database: db)
            case .onDevice(let file):
                try await WebDAVBackupService.shared.restore(from: file.url, database: db)
            case .remote(let file, _) where file.isLegacySnapshot:
                try await restoreLegacy(file, database: db)
                message = "已从旧版同步文件恢复。"
                return
            case .remote(let file, let isLatest):
                try await WebDAVBackupService.shared.restoreRemote(file, database: db, account: account, isLatest: isLatest)
            case .conflict, .legacy: return
            }
            try didRestore()
        }
    }

    private func didRestore() throws {
        account = try WebDAVAccount.load() ?? WebDAVAccount()
        message = "备份已恢复。"
    }
}

private struct BackupHistoryLabel: View {
    let name: String
    let date: Date
    let size: Int64?
    var legacy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(date.formatted(date: .abbreviated, time: .standard)).foregroundStyle(.primary)
            Text(name).font(.caption).foregroundStyle(.secondary)
            if legacy {
                Text("旧版同步文件").font(.caption).foregroundStyle(.secondary)
            } else if let size {
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor
private struct RemoteBackupHistoryView: View {
    @State private var files: [WebDAVBackupFile]
    let client: WebDAVSync
    let onCancel: () -> Void
    let onRestore: (WebDAVBackupFile, Bool) -> Void

    private enum Transfer: String {
        case copy = "复制", rename = "重命名"
    }

    private enum Prompt {
        case properties(WebDAVBackupFile, Int64?), delete(WebDAVBackupFile)

        var title: String {
            switch self {
            case .properties: "文件属性"
            case .delete: "删除云端备份？"
            }
        }

        var detail: String {
            switch self {
            case .properties(let file, let bytes):
                let size = bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
                let date = file.date == .distantPast ? "" : "\n日期：\(file.date.formatted(date: .abbreviated, time: .standard))"
                return "\(file.name)\(date)\n大小：\(size ?? "服务器未提供")"
            case .delete(let file):
                return "将从 WebDAV 目录删除“\(file.name)”。此操作无法撤销。"
            }
        }
    }

    @State private var editing: (action: Transfer, file: WebDAVBackupFile)?
    @State private var destination = ""
    @State private var prompt: Prompt?
    @State private var progress: String?
    @State private var notice: String?
    @State private var hasCompleteListing = true

    init(files: [WebDAVBackupFile], client: WebDAVSync, onCancel: @escaping () -> Void,
         onRestore: @escaping (WebDAVBackupFile, Bool) -> Void) {
        _files = State(initialValue: files)
        self.client = client
        self.onCancel = onCancel
        self.onRestore = onRestore
    }

    var body: some View {
        ReadingNavigationStack {
            Group {
                if let editing {
                    Form {
                        Section("原文件") { Text(editing.file.name) }
                        Section("新文件名") {
                            TextField("文件名.zip", text: $destination)
                                .textInputAutocapitalization(.never)
                                .disableAutocorrection(true)
                                .accessibilityIdentifier("backup.remote.filename")
                        }
                    }
                } else {
                    fileList
                }
            }
            .disabled(progress != nil)
            .safeAreaInset(edge: .top, spacing: 0) {
                if let text = progress ?? notice {
                    HStack {
                        if progress != nil { ProgressView() }
                        Text(text).font(.callout).accessibilityIdentifier("backup.remote.status")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal).padding(.vertical, 8)
                    .background(.bar)
                }
            }
            .navigationTitle(editing.map { $0.action.rawValue + "备份" } ?? "云端备份")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        if editing == nil {
                            onCancel()
                        } else {
                            editing = nil
                            notice = nil
                        }
                    }
                    .disabled(progress != nil)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if let editing {
                        Button(editing.action.rawValue) { transfer(editing.action, editing.file, to: destination) }
                            .disabled(progress != nil || destination.isEmpty || destination == editing.file.name)
                    } else {
                        Button { run("正在刷新列表…") { try await reload() } } label: {
                            Label("刷新", systemImage: "arrow.clockwise")
                        }
                        .disabled(progress != nil)
                    }
                }
            }
            .alert(prompt?.title ?? "", isPresented: Binding(
                get: { prompt != nil }, set: { if !$0 { prompt = nil } }
            ), presenting: prompt) { selected in
                switch selected {
                case .properties:
                    Button("好") {}
                case .delete(let file):
                    Button("删除", role: .destructive) {
                        run("正在删除备份…") {
                            try await client.deleteBackup(file)
                            files.removeAll { $0.id == file.id }
                            await refreshAfterChange("已删除“\(file.name)”。")
                        }
                    }
                    Button("取消", role: .cancel) {}
                }
            } message: { selected in
                Text(selected.detail)
            }
        }
        .interactiveDismissDisabled(progress != nil)
    }

    private var fileList: some View {
        List {
            if files.isEmpty && hasCompleteListing { Text("这个目录还没有备份。").foregroundStyle(.secondary) }
            let latest = hasCompleteListing ? files.first(where: \.isSyncArchive) : nil
            ForEach(files) { file in
                HStack {
                    Button { onRestore(file, file == latest) } label: {
                        BackupHistoryLabel(name: file.name, date: file.date, size: file.size, legacy: file.isLegacySnapshot)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(file.name)
                    .accessibilityValue(file.date.formatted(date: .abbreviated, time: .standard))
                    .accessibilityIdentifier("backup.remote." + file.name)
                    Menu {
                        Button("属性") {
                            run("正在读取文件属性…") {
                                let bytes = try await client.backupSize(file)
                                prompt = .properties(file, bytes)
                            }
                        }
                        if !file.isLegacySnapshot {
                            Button("复制") { edit(.copy, file) }
                            Button("重命名") { edit(.rename, file) }
                            Button("删除", role: .destructive) { prompt = .delete(file) }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("\(file.name)的更多操作")
                    .accessibilityIdentifier("backup.remote.actions." + file.name)
                }
            }
        }
    }

    private func edit(_ action: Transfer, _ file: WebDAVBackupFile) {
        notice = nil
        destination = action == .copy ? String(file.name.dropLast(4)) + " 副本.zip" : file.name
        editing = (action, file)
    }

    private func transfer(_ action: Transfer, _ file: WebDAVBackupFile, to name: String) {
        run("正在\(action.rawValue)备份…") {
            switch action {
            case .copy:
                try await client.copyBackup(file, to: name)
            case .rename:
                try await client.moveBackup(file, to: name)
                files.removeAll { $0.id == file.id }
            }
            editing = nil
            await refreshAfterChange("已\(action.rawValue)为“\(name)”。")
        }
    }

    private func run(_ description: String, _ operation: @escaping @MainActor () async throws -> Void) {
        guard progress == nil else { return }
        progress = description
        notice = nil
        Task {
            defer { progress = nil }
            do { try await operation() }
            catch { notice = error.localizedDescription }
        }
    }

    private func reload() async throws {
        files = try await client.listBackups(includeOtherArchives: true)
        hasCompleteListing = true
    }

    private func refreshAfterChange(_ receipt: String) async {
        hasCompleteListing = false
        progress = "正在刷新列表…"
        do {
            try await reload()
            notice = receipt
        } catch {
            notice = "\(receipt) 列表刷新失败：\(error.localizedDescription) 请点“刷新”重试。"
        }
    }
}

final class TemporaryBackup: Sendable {
    let url: URL
    let name: String

    private init(url: URL, name: String) {
        self.url = url
        self.name = name
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    static func importCopy(of file: SourceImportFile) throws -> TemporaryBackup {
        defer { withExtendedLifetime(file) {} }
        try Task.checkCancellation()
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).zip")
        let copy = TemporaryBackup(url: target, name: file.url.lastPathComponent)
        var error: NSError?
        var copyResult: Result<Void, Error>?
        NSFileCoordinator().coordinate(readingItemAt: file.url, options: [], error: &error) { source in
            copyResult = Result {
                guard try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    throw SyncViewError("请选择 ZIP 备份文件。")
                }
                try Task.checkCancellation()
                try FileManager.default.copyItem(at: source, to: target)
            }
        }
        if let error { throw error }
        guard let copyResult else { throw CocoaError(.fileReadUnknown) }
        try copyResult.get()
        try Task.checkCancellation()
        do {
            _ = try LegadoDatabase.fullBackupFingerprint(at: target)
        } catch {
            throw SyncViewError("所选文件不是有效的阅读备份 ZIP。")
        }
        try Task.checkCancellation()
        return copy
    }
}

private struct SyncViewError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

struct WebDAVAccount: Codable, Equatable, Sendable {
    var directory = ""
    var username = ""
    var password = ""

    mutating func completeDirectory() throws {
        let url = try WebDAVAddress.complete(directory)
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw WebDAVSyncError.invalidDirectory
        }
        if username.isEmpty {
            username = parts.user ?? ""
            if password.isEmpty { password = parts.password ?? "" }
        }
        parts.user = nil
        parts.password = nil
        parts.fragment = nil
        guard let address = parts.url else { throw WebDAVSyncError.invalidDirectory }
        directory = address.absoluteString
    }

    mutating func apply(_ preset: WebDAVAddress.Preset) throws {
        let old = try? WebDAVAddress.complete(directory)
        let login = old.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.user }
        let address = try preset.directory(for: directory, username: username.isEmpty ? login ?? "" : username)
        if let old, let new = URL(string: address) {
            func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
            if old.host?.lowercased() != new.host?.lowercased() ||
                old.scheme?.lowercased() != new.scheme?.lowercased() || port(old) != port(new) {
                password = ""
            } else {
                try completeDirectory()
            }
        }
        directory = address
    }

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
        let changes: [String: Any] = [kSecValueData as String: data,
                                      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let updated = SecItemUpdate(Self.query as CFDictionary, changes as CFDictionary)
        if updated == errSecItemNotFound {
            var item = Self.query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            try Self.check(SecItemAdd(item as CFDictionary, nil))
        } else {
            try Self.check(updated)
        }
    }

    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    func makeClient() throws -> WebDAVSync {
        try WebDAVSync(directoryURL: directory, username: username, password: password)
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw SyncViewError("无法访问本机钥匙串（\(status)）。")
        }
    }
}
