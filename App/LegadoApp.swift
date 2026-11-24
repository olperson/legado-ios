import SwiftUI

@main
struct LegadoApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(LegadoAppDelegate.self) private var appDelegate
    @StateObject private var library: ApplicationLibrary
    @ObservedObject private var backups = WebDAVBackupService.shared

    init() {
        AppDiagnostics.shared.start()
        SourceWebViewExecutorRegistry.shared.register(WKSourceWebViewExecutor())
        let demo = ProcessInfo.processInfo.arguments.contains("-uiDemo")
        let database = demo ? nil : try? LegadoDatabase(url: LegadoDatabase.defaultURL())
        if !demo {
            WebDAVBackupScheduler.shared.configure { destinations, didSave in
                guard let database else { throw LibraryRestoreError.unavailable }
                try await WebDAVBackupService.shared.automaticBackup(database: database, destinations: destinations, didSave: didSave)
            }
        }
        let library = ApplicationLibrary(demo: demo, database: database)
        _library = StateObject(wrappedValue: library)
        WebDAVBackupService.shared.canRestore = { [weak library] in library?.models.canRestore == true }
        WebDAVBackupService.shared.stableFileRevision = { [weak library] in library?.models.bookLibrary.stableFileRevision }
        WebDAVBackupService.shared.didRestore = { [weak library] in
            await library?.reloadAfterRestore()
        }
    }

    var body: some Scene {
        let models = library.models
        let sourceLibrary = models.sourceLibrary
        let bookLibrary = models.bookLibrary
        let replaceRuleLibrary = models.replaceRuleLibrary
        let readingActivity = models.readingActivity
        let rssLibrary = models.rssLibrary
        let ruleSubscriptions = models.ruleSubscriptions
        return WindowGroup {
            RootTabView()
                .environmentObject(sourceLibrary)
                .environmentObject(bookLibrary)
                .environmentObject(replaceRuleLibrary)
                .environmentObject(readingActivity)
                .environmentObject(rssLibrary)
                .environmentObject(ruleSubscriptions)
                .id(models.id)
                .disabled(backups.isRestoring)
                .task {
                    guard !models.loadedAfterRestore else { return }
                    if let database = bookLibrary.syncDatabase {
                        try? await backups.resumeAfterInterruption(database: database)
                    }
                    await sourceLibrary.load()
                    if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-uiAutomationImportURL"),
                       ProcessInfo.processInfo.arguments.indices.contains(index + 1),
                       let url = URL(string: ProcessInfo.processInfo.arguments[index + 1]) {
                        await sourceLibrary.handleDeepLink(url)
                        if ProcessInfo.processInfo.arguments.contains("-uiAutomation") {
                            sourceLibrary.notice = nil
                        }
                    }
                    await bookLibrary.load()
                    await replaceRuleLibrary.load()
                    await readingActivity.load()
                    await rssLibrary.load()
                    await ruleSubscriptions.load()
                    if UserDefaults.standard.bool(forKey: "auto_refresh") {
                        await bookLibrary.checkForUpdates(sources: sourceLibrary.sources, onlyRead: UserDefaults.standard.bool(forKey: "onlyUpdateRead"))
                    }
                    await ruleSubscriptions.checkAutomaticUpdates(bookSources: sourceLibrary, rssSources: rssLibrary, replaceRules: replaceRuleLibrary)
                }
                .onOpenURL { url in
                    guard !backups.isRestoring else { return }
                    Task {
                        if url.isFileURL && url.pathExtension.lowercased() == "epub" {
                            let file = LocalBookImportFile(url: url)
                            await bookLibrary.load()
                            await bookLibrary.importPickedLocalFiles([file])
                            sourceLibrary.notice = .init(kind: bookLibrary.errorMessage == nil ? .success : .error,
                                                         title: bookLibrary.errorMessage == nil ? "EPUB 已加入书架" : "导入失败",
                                                         detail: bookLibrary.errorMessage ?? url.lastPathComponent)
                            return
                        }
                        await sourceLibrary.load()
                        if RuleImportInput.isDeepLink(url, for: "replaceRule") {
                            await replaceRuleLibrary.load()
                            await replaceRuleLibrary.importText(url.absoluteString)
                            if let notice = replaceRuleLibrary.notice {
                                sourceLibrary.notice = .init(kind: notice.kind == .error ? .error : .success, title: notice.title, detail: notice.detail)
                                replaceRuleLibrary.notice = nil
                            }
                        } else { await sourceLibrary.handleDeepLink(url) }
                    }
                }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active, let database = bookLibrary.syncDatabase {
                Task {
                    try? await backups.resumeAfterInterruption(database: database)
                    WebDAVBackupScheduler.shared.sceneChanged(scenePhase)
                }
            } else {
                WebDAVBackupScheduler.shared.sceneChanged(phase)
            }
        }
    }
}

@MainActor
private final class ApplicationLibrary: ObservableObject {
    @Published private(set) var models: ApplicationModels
    private let database: LegadoDatabase?

    init(demo: Bool, database: LegadoDatabase?) {
        self.database = database
        models = ApplicationModels(demo: demo, database: database)
    }

    func reloadAfterRestore() async {
        let restored = ApplicationModels(demo: false, database: database)
        await restored.sourceLibrary.load()
        await restored.bookLibrary.load()
        await restored.replaceRuleLibrary.load()
        await restored.readingActivity.load()
        await restored.rssLibrary.load()
        await restored.ruleSubscriptions.load()
        restored.loadedAfterRestore = true
        models = restored
        restored.sourceLibrary.notice = .init(kind: .success, title: "备份已恢复", detail: "书架和设置已重新载入。")
    }
}

@MainActor
private final class ApplicationModels {
    let id = UUID()
    var loadedAfterRestore = false
    let sourceLibrary: SourceLibraryModel
    let bookLibrary: BookLibraryModel
    let replaceRuleLibrary: ReplaceRuleLibraryModel
    let readingActivity: ReadingActivityModel
    let rssLibrary: RSSLibraryModel
    let ruleSubscriptions: RuleSubscriptionModel

    var canRestore: Bool {
        sourceLibrary.canRestoreSnapshot && bookLibrary.canRestoreSnapshot && readingActivity.canRestoreSnapshot &&
            replaceRuleLibrary.canRestoreSnapshot && ruleSubscriptions.canRestoreSnapshot && !rssLibrary.isWorking
    }

    init(demo: Bool, database: LegadoDatabase?) {
        sourceLibrary = demo
            ? SourceLibraryModel.demo(sources: DemoContent.sources)
            : SourceLibraryModel.live(database: database)
        bookLibrary = demo
            ? BookLibraryModel.demo(books: DemoContent.books)
            : BookLibraryModel.live(database: database)
        replaceRuleLibrary = demo
            ? ReplaceRuleLibraryModel.demo()
            : ReplaceRuleLibraryModel.live()
        readingActivity = demo
            ? ReadingActivityModel.demo(bookmarks: DemoContent.bookmarks, records: DemoContent.readRecords)
            : ReadingActivityModel.live(database: database)
        rssLibrary = database.map { RSSLibraryModel(database: $0) } ?? RSSLibraryModel.live()
        ruleSubscriptions = RuleSubscriptionModel(repository: database.map { SQLiteConfigurationRepository(database: $0) })
    }
}

final class LegadoAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if !ProcessInfo.processInfo.arguments.contains("-uiDemo") { WebDAVBackupScheduler.shared.registerBackgroundTask() }
        return true
    }

    func applicationSignificantTimeChange(_ application: UIApplication) {
        WebDAVBackupScheduler.shared.clockChanged()
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        ReaderScreenOrientation.supportedOrientations
    }
}
