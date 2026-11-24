import Foundation
import Testing
@testable import LegadoCore

struct BackupScheduleTests {
    let start = Date(timeIntervalSince1970: 0)

    private func calendar(_ zone: String = "UTC") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    @Test func simultaneousTriggersMakeOneBackupWithoutRebasingOtherTimers() {
        var settings = BackupScheduleSettings()
        settings.onOpening = true
        settings.onInterval = true
        settings.intervalMinutes = 60
        settings.atFixedTime = true
        settings.minuteOfDay = 60
        var state = BackupScheduleState()
        state.reconcile(settings, now: start, calendar: calendar())
        let hour = start.addingTimeInterval(3600)
        #expect(state.nextInterval == hour && state.nextDaily == hour)
        state.opened(settings)
        state.completed(at: start.addingTimeInterval(300), calendar: calendar())
        #expect(state.nextInterval == hour && state.nextDaily == hour)
        state.opened(settings)
        #expect(state.nextAttempt(at: hour) == hour)
        state.completed(at: hour.addingTimeInterval(10), calendar: calendar())
        #expect(state.nextInterval == hour.addingTimeInterval(3600))
        #expect(state.nextDaily == hour.addingTimeInterval(86400))
    }

    @Test func persistedPartialSuccessRetriesOnlyMissingTargetAfterRelaunch() throws {
        var settings = BackupScheduleSettings()
        settings.onOpening = true
        settings.destinations = [.local, .webDAV]
        var state = BackupScheduleState()
        state.reconcile(settings, now: start, calendar: calendar())
        state.opened(settings)
        state.recordedSave(to: .local)
        state.failed(at: start, message: "WebDAV 离线")
        var relaunched = try JSONDecoder().decode(BackupScheduleState.self, from: JSONEncoder().encode(state))
        relaunched.reconcile(settings, now: start.addingTimeInterval(60), calendar: calendar())
        #expect(settings.destinations.subtracting(relaunched.saved) == [.webDAV])
        #expect(relaunched.nextAttempt(at: start.addingTimeInterval(60)) == start.addingTimeInterval(900))
        relaunched.recordedSave(to: .webDAV)
        relaunched.completed(at: start.addingTimeInterval(901), calendar: calendar())
        #expect(relaunched.saved.isEmpty && relaunched.lastError == nil)
        #expect(relaunched.nextAttempt(at: start.addingTimeInterval(901)) == nil)
    }

    @Test func disabledTriggerCancelsRetriesAndIncompleteDestinations() {
        var settings = BackupScheduleSettings()
        settings.onInterval = true
        settings.intervalMinutes = 10
        var state = BackupScheduleState()
        state.reconcile(settings, now: start, calendar: calendar())
        let later = start.addingTimeInterval(1000)
        state.recordedSave(to: .local)
        state.failed(at: later, message: "Interrupted")
        settings.onInterval = false
        state.reconcile(settings, now: later, calendar: calendar())
        #expect(state.nextAttempt(at: later) == nil)
        #expect(state.saved.isEmpty)
        settings.onOpening = true
        state.reconcile(settings, now: later, calendar: calendar())
        state.opened(settings)
        #expect(state.nextAttempt(at: later) == later)
    }

    @Test func missedDaysCatchUpOnceAndUseLocalClockAcrossDST() throws {
        let local = calendar("America/Los_Angeles")
        let before = try #require(local.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 21)))
        var settings = BackupScheduleSettings()
        settings.atFixedTime = true
        settings.minuteOfDay = 2 * 60 + 30
        var state = BackupScheduleState()
        state.reconcile(settings, now: before, calendar: local)
        let due = try #require(state.nextDaily)
        #expect(local.component(.day, from: due) == 8)
        #expect(local.component(.hour, from: due) == 3)
        let reopened = try #require(local.date(from: DateComponents(year: 2026, month: 3, day: 12, hour: 12)))
        state.reconcile(settings, now: reopened, calendar: local)
        #expect(state.nextAttempt(at: reopened) == due)
        state.completed(at: reopened, calendar: local)
        let next = try #require(state.nextDaily)
        #expect(local.component(.day, from: next) == 13 && local.component(.hour, from: next) == 2)
        #expect(local.component(.minute, from: next) == 30)
    }
}
