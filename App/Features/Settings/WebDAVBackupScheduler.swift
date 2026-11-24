@preconcurrency import BackgroundTasks
import SwiftUI
import UIKit

@MainActor
final class WebDAVBackupScheduler: ObservableObject {
    static let shared = WebDAVBackupScheduler()
    private static let identifier = "com.epiboly.legado.backup"
    private static let settingsKey = "webdav.schedule.settings"
    private static let runtimeKey = "webdav.schedule.runtime"

    typealias DidSave = @MainActor (BackupDestination) -> Void
    typealias Backup = @MainActor (Set<BackupDestination>, @escaping DidSave) async throws -> Void

    @Published private(set) var settings = BackupScheduleSettings()
    @Published private(set) var state = BackupScheduleState()

    private var backup: Backup?
    private var waitForDueDate: Task<Void, Never>?
    private var work: Task<Bool, Never>?
    private var backgroundTask: BGProcessingTask?
    private var backgroundRun: UUID?
    private var registered = false
    private var foreground = false

    private init() { reloadSettings() }

    func configure(_ backup: @escaping Backup) {
        self.backup = backup
        replan()
    }

    func registerBackgroundTask() {
        registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: .main) { task in
            guard let processing = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            // BackgroundTasks runs this callback on the main queue requested above.
            nonisolated(unsafe) let mainQueueTask = processing
            MainActor.assumeIsolated { WebDAVBackupScheduler.shared.handle(mainQueueTask) }
        }
        replan()
    }

    func reloadSettings() {
        let decoder = JSONDecoder()
        let defaults = UserDefaults.standard
        settings = defaults.data(forKey: Self.settingsKey).flatMap { try? decoder.decode(BackupScheduleSettings.self, from: $0) } ?? .init()
        settings.normalize()
        if work == nil {
            state = defaults.data(forKey: Self.runtimeKey).flatMap { try? decoder.decode(BackupScheduleState.self, from: $0) } ?? .init()
        }
        clockChanged()
    }

    func changeSettings(_ updated: BackupScheduleSettings) {
        settings = updated
        settings.normalize()
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: Self.settingsKey) }
        clockChanged()
    }

    func clockChanged() {
        state.reconcile(settings, now: Date(), calendar: .current)
        persistState()
        replan()
    }

    func sceneChanged(_ phase: ScenePhase) {
        if phase == .active, !foreground {
            foreground = true
            state.opened(settings)
            clockChanged()
        } else if phase == .background, foreground {
            foreground = false
            clockChanged()
        }
    }

    private func persistState() {
        if let data = try? JSONEncoder().encode(state) { UserDefaults.standard.set(data, forKey: Self.runtimeKey) }
    }

    private func replan() {
        waitForDueDate?.cancel()
        waitForDueDate = nil
        guard backup != nil else { return }
        let now = Date()
        guard let due = state.nextAttempt(at: now) else {
            if registered { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier) }
            return
        }
        if registered {
            let request = BGProcessingTaskRequest(identifier: Self.identifier)
            // Give a terminated in-flight task a chance to resume on a later system launch.
            request.earliestBeginDate = work == nil ? due : max(due, now.addingTimeInterval(15 * 60))
            request.requiresNetworkConnectivity = settings.destinations.subtracting(state.saved) == [.webDAV]
            try? BGTaskScheduler.shared.submit(request)
        }
        guard foreground, work == nil else { return }
        if due <= now {
            _ = runIfDue()
        } else {
            waitForDueDate = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(min(due.timeIntervalSince(now), 86_400) * 1e9)) }
                catch { return }
                self?.clockChanged()
            }
        }
    }

    private func runIfDue() -> Task<Bool, Never>? {
        if let work { return work }
        let now = Date()
        guard let backup, let due = state.nextAttempt(at: now), due <= now else { return nil }
        let remaining = settings.destinations.subtracting(state.saved)
        let job = Task { @MainActor in
            var failure: Error?
            if !remaining.isEmpty {
                do {
                    try await backup(remaining) { destination in
                        self.state.recordedSave(to: destination)
                        self.persistState()
                    }
                } catch { failure = error }
            }
            let succeeded = self.settings.destinations.isSubset(of: self.state.saved)
            if succeeded {
                self.state.completed(at: Date(), calendar: .current)
            } else {
                self.state.failed(at: Date(), message: failure?.localizedDescription ?? "备份未完成，将重试剩余位置。")
            }
            self.persistState()
            self.work = nil
            self.replan()
            return succeeded
        }
        work = job
        return job
    }

    private func handle(_ task: BGProcessingTask) {
        let now = Date()
        state.reconcile(settings, now: now, calendar: .current)
        persistState()
        guard let job = runIfDue() else {
            task.setTaskCompleted(success: true)
            replan()
            return
        }
        let identifier = UUID()
        backgroundRun = identifier
        backgroundTask = task
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                guard let self, self.backgroundRun == identifier else { return }
                if !self.foreground { job.cancel() }
                self.finishBackgroundTask(success: false)
            }
        }
        replan()
        Task { @MainActor in
            let succeeded = await job.value
            if backgroundRun == identifier { finishBackgroundTask(success: succeeded) }
        }
    }

    private func finishBackgroundTask(success: Bool) {
        backgroundTask?.expirationHandler = nil
        backgroundTask?.setTaskCompleted(success: success)
        backgroundTask = nil
        backgroundRun = nil
    }
}

@MainActor
struct WebDAVAutoBackupSection: View {
    @ObservedObject private var scheduler = WebDAVBackupScheduler.shared
    private let intervals = [15, 30, 60, 120, 360, 720, 1440, 4320, 10080]

    var body: some View {
        Section {
            Toggle("打开应用时备份", isOn: binding(\.onOpening))
            Toggle("按间隔备份", isOn: binding(\.onInterval))
            if scheduler.settings.onInterval {
                Picker("备份间隔", selection: binding(\.intervalMinutes)) {
                    ForEach(Array(Set(intervals + [scheduler.settings.intervalMinutes])).sorted(), id: \.self) { minutes in
                        Text(intervalLabel(minutes)).tag(minutes)
                    }
                }
            }
            Toggle("每日定时备份", isOn: binding(\.atFixedTime))
            if scheduler.settings.atFixedTime {
                DatePicker("本地时间", selection: fixedTime, displayedComponents: .hourAndMinute)
            }
            if scheduler.settings.enabled {
                Toggle("备份到本地", isOn: destination(.local))
                    .disabled(scheduler.settings.destinations == [.local])
                Toggle("备份到 WebDAV", isOn: destination(.webDAV))
                    .disabled(scheduler.settings.destinations == [.webDAV])
            }
            if let last = scheduler.state.lastSuccess {
                Text("上次自动备份：\(last.formatted(date: .abbreviated, time: .shortened))")
                    .font(.footnote)
            }
            if let problem = scheduler.state.lastError, scheduler.settings.enabled {
                Text("上次自动备份未完成：\(problem)").font(.footnote)
            }
        } header: {
            Text("自动备份")
        } footer: {
            Text("可以同时启用多种时间和位置。后台执行时间由 iOS 安排，错过的备份会在下次打开时补做。")
        }
    }

    private func binding<Value>(_ key: WritableKeyPath<BackupScheduleSettings, Value>) -> Binding<Value> {
        Binding(get: { scheduler.settings[keyPath: key] }, set: { value in
            var updated = scheduler.settings
            updated[keyPath: key] = value
            scheduler.changeSettings(updated)
        })
    }

    private func destination(_ destination: BackupDestination) -> Binding<Bool> {
        Binding(get: { scheduler.settings.destinations.contains(destination) }, set: { enabled in
            var updated = scheduler.settings
            if enabled { updated.destinations.insert(destination) } else { updated.destinations.remove(destination) }
            scheduler.changeSettings(updated)
        })
    }

    private var fixedTime: Binding<Date> {
        Binding(get: {
            let minute = scheduler.settings.minuteOfDay
            return Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            var updated = scheduler.settings
            updated.minuteOfDay = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            scheduler.changeSettings(updated)
        })
    }

    private func intervalLabel(_ minutes: Int) -> String {
        if minutes.isMultiple(of: 1440) { return "\(minutes / 1440) 天" }
        if minutes.isMultiple(of: 60) { return "\(minutes / 60) 小时" }
        return "\(minutes) 分钟"
    }
}
