import Foundation

enum BackupDestination: String, Codable, CaseIterable, Sendable {
    case local
    case webDAV
}

struct BackupScheduleSettings: Codable, Equatable, Sendable {
    var onOpening = false
    var onInterval = false
    var intervalMinutes = 360
    var atFixedTime = false
    var minuteOfDay = 21 * 60
    var destinations: Set<BackupDestination> = [.local]

    var enabled: Bool { onOpening || onInterval || atFixedTime }

    mutating func normalize() {
        intervalMinutes = min(max(intervalMinutes, 1), 60 * 24 * 30)
        minuteOfDay = min(max(minuteOfDay, 0), 1439)
        if destinations.isEmpty { destinations = [.local] }
    }
}

struct BackupScheduleState: Codable, Equatable, Sendable {
    private var intervalMinutes: Int?
    private var minuteOfDay: Int?
    private var timeZone: String?
    private(set) var nextInterval: Date?
    private(set) var nextDaily: Date?
    private var pendingOpening = false
    private(set) var saved: Set<BackupDestination> = []
    private var retryAfter: Date?
    private(set) var lastSuccess: Date?
    private(set) var lastError: String?

    mutating func reconcile(_ settings: BackupScheduleSettings, now: Date, calendar: Calendar) {
        let interval = settings.onInterval ? settings.intervalMinutes : nil
        if interval != intervalMinutes {
            intervalMinutes = interval
            nextInterval = interval.map { now.addingTimeInterval(Double($0) * 60) }
        }
        let fixedTime = settings.atFixedTime ? settings.minuteOfDay : nil
        if minuteOfDay != fixedTime || timeZone != calendar.timeZone.identifier {
            minuteOfDay = fixedTime
            timeZone = calendar.timeZone.identifier
            nextDaily = nextDailyOccurrence(after: now, calendar: calendar)
        }
        if !settings.onOpening { pendingOpening = false }
        if !isDue(at: now) {
            saved = []
            retryAfter = nil
        }
    }

    mutating func opened(_ settings: BackupScheduleSettings) {
        if settings.onOpening { pendingOpening = true }
    }

    mutating func recordedSave(to destination: BackupDestination) {
        saved.insert(destination)
    }

    mutating func completed(at now: Date, calendar: Calendar) {
        if let minutes = intervalMinutes, let due = nextInterval, due <= now {
            // Keep the interval tied to its own schedule even when an opening or fixed-time backup also ran.
            let interval = Double(minutes) * 60
            let periods = floor(now.timeIntervalSince(due) / interval) + 1
            nextInterval = due.addingTimeInterval(periods * interval)
        }
        if let due = nextDaily, due <= now {
            nextDaily = nextDailyOccurrence(after: now, calendar: calendar)
        }
        pendingOpening = false
        saved = []
        retryAfter = nil
        lastError = nil
        lastSuccess = now
    }

    mutating func failed(at now: Date, message: String) {
        lastError = message
        retryAfter = now.addingTimeInterval(15 * 60)
    }

    func nextAttempt(at now: Date) -> Date? {
        guard let first = [pendingOpening ? now : nil, nextInterval, nextDaily].compactMap({ $0 }).min() else { return nil }
        return max(first, retryAfter ?? .distantPast)
    }

    private func isDue(at date: Date) -> Bool {
        pendingOpening || nextInterval.map { $0 <= date } == true || nextDaily.map { $0 <= date } == true
    }

    private func nextDailyOccurrence(after date: Date, calendar: Calendar) -> Date? {
        guard let minuteOfDay else { return nil }
        let time = DateComponents(hour: minuteOfDay / 60, minute: minuteOfDay % 60, second: 0)
        // On clock changes, use the first matching time and still run on spring-forward days.
        return calendar.nextDate(after: date, matching: time, matchingPolicy: .nextTimePreservingSmallerComponents,
                                 repeatedTimePolicy: .first, direction: .forward)
    }
}
