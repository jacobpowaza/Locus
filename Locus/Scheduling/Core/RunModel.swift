import Foundation

/// A named place used by Set Location / Drive To.
struct PlaceRef: Codable, Equatable, Hashable {
    var name: String
    var point: GeoPoint
}

/// Wall-clock time of day, interpreted in a run's time zone.
struct TimeOfDay: Codable, Equatable, Hashable, Comparable {
    var hour: Int
    var minute: Int

    init(hour: Int, minute: Int) {
        self.hour = min(23, max(0, hour))
        self.minute = min(59, max(0, minute))
    }

    var minutesSinceMidnight: Int { hour * 60 + minute }

    static func < (a: TimeOfDay, b: TimeOfDay) -> Bool { a.minutesSinceMidnight < b.minutesSinceMidnight }

    /// "10:30" (24h) — UI formats with the user's locale instead.
    var description24h: String { String(format: "%02d:%02d", hour, minute) }
}

/// One block in a run.
enum RunActionKind: Codable, Equatable, Hashable {
    /// Instantly move the simulated location.
    case setLocation(PlaceRef)
    /// Drive along roads from the current simulated location. `speed`
    /// overrides the run's current speed for this leg only ("Custom Speed").
    case driveTo(PlaceRef, speed: SpeedPolicy?)
    /// Stay put for a duration (seconds).
    case wait(seconds: Double)
    /// Hold until a wall-clock time. `dayOffset` = days after the day the run started.
    case startAt(TimeOfDay, dayOffset: Int)
    /// Change speed behaviour for following drives.
    case setSpeed(SpeedPolicy)
    /// End location simulation (device returns to real GPS).
    case stopSpoofing
    /// Repeat the previous `count` actions `times` more times.
    case repeatPrevious(count: Int, times: Int)

    enum Category: String, CaseIterable {
        case setLocation, driveTo, wait, startAt, setSpeed, stopSpoofing, repeatPrevious
    }

    var category: Category {
        switch self {
        case .setLocation: return .setLocation
        case .driveTo: return .driveTo
        case .wait: return .wait
        case .startAt: return .startAt
        case .setSpeed: return .setSpeed
        case .stopSpoofing: return .stopSpoofing
        case .repeatPrevious: return .repeatPrevious
        }
    }
}

struct RunAction: Codable, Equatable, Hashable, Identifiable {
    var id: UUID
    var kind: RunActionKind

    init(id: UUID = UUID(), _ kind: RunActionKind) {
        self.id = id
        self.kind = kind
    }

    /// Copy with a fresh identity (Duplicate).
    func duplicated() -> RunAction { RunAction(kind) }
}

/// When a run starts on its own.
enum RunSchedule: Codable, Equatable, Hashable {
    /// Only when the user taps Run.
    case manual
    /// Once, at an absolute instant.
    case once(Date)
    /// Every selected weekday at a time of day. Weekdays use Calendar
    /// numbering (1 = Sunday … 7 = Saturday). `timeZoneID == nil` follows
    /// the device's current time zone.
    case recurring(TimeOfDay, weekdays: Set<Int>, timeZoneID: String?)

    var isAutomatic: Bool {
        if case .manual = self { return false }
        return true
    }

    static let everyDay: Set<Int> = Set(1...7)
    static let weekdaysOnly: Set<Int> = Set(2...6)
}

/// What to do when Locus wasn't running at a scheduled start time.
struct LatePolicy: Codable, Equatable, Hashable {
    /// Start anyway if no more than this many seconds late; 0 = skip.
    var maxDelay: Double = 15 * 60

    static let standard = LatePolicy()
}

/// The selected geometry for a specific leg and its original endpoints.
struct PreferredRoute: Codable, Equatable {
    var origin: GeoPoint
    var destination: GeoPoint
    var route: RouteResult
}

struct ScheduledRun: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var actions: [RunAction]
    var schedule: RunSchedule
    var isEnabled: Bool
    /// Speed for drives until a Set Speed action changes it.
    var defaultSpeed: SpeedPolicy
    var motion: MotionSettings
    var latePolicy: LatePolicy
    /// Index into the UI palette for the run's tile.
    var tint: Int
    var createdAt: Date
    var updatedAt: Date
    /// The most recent occurrence that was started, skipped, or missed —
    /// prevents running the same occurrence twice.
    var lastHandledOccurrence: Date?
    /// Duration from the last successful preview/compile, for overlap checks.
    var estimatedDuration: Double?
    var isSavedRoute: Bool? = nil
    var preferredRoutes: [UUID: PreferredRoute]? = nil

    init(
        id: UUID = UUID(),
        name: String,
        actions: [RunAction] = [],
        schedule: RunSchedule = .manual,
        isEnabled: Bool = true,
        defaultSpeed: SpeedPolicy = .followLimit,
        motion: MotionSettings = .standard,
        latePolicy: LatePolicy = .standard,
        tint: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        lastHandledOccurrence: Date? = nil,
        estimatedDuration: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.actions = actions
        self.schedule = schedule
        self.isEnabled = isEnabled
        self.defaultSpeed = defaultSpeed
        self.motion = motion
        self.latePolicy = latePolicy
        self.tint = tint
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.lastHandledOccurrence = lastHandledOccurrence
        self.estimatedDuration = estimatedDuration
    }

    /// Time zone used for the schedule and for Start At steps.
    var timeZone: TimeZone {
        if case .recurring(_, _, let id?) = schedule, let tz = TimeZone(identifier: id) { return tz }
        return TimeZone.current
    }
}

// MARK: - Editing helpers (used by the builder UI, unit-tested)

extension ScheduledRun {
    mutating func insertAction(_ action: RunAction, at index: Int? = nil) {
        let i = min(max(0, index ?? actions.count), actions.count)
        actions.insert(action, at: i)
    }

    mutating func deleteAction(id: UUID) {
        actions.removeAll { $0.id == id }
    }

    /// Inserts a copy directly after the original.
    @discardableResult
    mutating func duplicateAction(id: UUID) -> RunAction? {
        guard let i = actions.firstIndex(where: { $0.id == id }) else { return nil }
        let copy = actions[i].duplicated()
        actions.insert(copy, at: i + 1)
        return copy
    }

    /// Same semantics as SwiftUI's `onMove` / `Array.move(fromOffsets:toOffset:)`.
    mutating func moveActions(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted().map { actions[$0] }
        let before = source.filter { $0 < destination }.count
        for i in source.sorted(by: >) { actions.remove(at: i) }
        actions.insert(contentsOf: moving, at: min(actions.count, max(0, destination - before)))
    }

    /// A ready-to-edit example matching the feature brief (Home → Work commute).
    static func commuteTemplate(home: PlaceRef, work: PlaceRef, now: Date = Date()) -> ScheduledRun {
        ScheduledRun(
            name: "Morning Commute",
            actions: [
                RunAction(.startAt(TimeOfDay(hour: 10, minute: 0), dayOffset: 0)),
                RunAction(.setLocation(home)),
                RunAction(.wait(seconds: 15 * 60)),
                RunAction(.startAt(TimeOfDay(hour: 10, minute: 30), dayOffset: 0)),
                RunAction(.setSpeed(.followLimit)),
                RunAction(.driveTo(work, speed: nil)),
            ],
            schedule: .manual,
            createdAt: now
        )
    }
}
