import Foundation

struct RunIssue: Equatable, Hashable, Identifiable {
    enum Severity: String, Codable { case error, warning }

    var severity: Severity
    /// The action the issue is about, if any (nil = whole run / schedule).
    var actionID: UUID?
    var message: String

    var id: String { "\(severity.rawValue)|\(actionID?.uuidString ?? "-")|\(message)" }

    static func error(_ message: String, _ actionID: UUID? = nil) -> RunIssue {
        RunIssue(severity: .error, actionID: actionID, message: message)
    }

    static func warning(_ message: String, _ actionID: UUID? = nil) -> RunIssue {
        RunIssue(severity: .warning, actionID: actionID, message: message)
    }
}

extension Array where Element == RunIssue {
    var hasErrors: Bool { contains { $0.severity == .error } }
    func forAction(_ id: UUID) -> [RunIssue] { filter { $0.actionID == id } }
}

/// Static checks that need no routing or clock. Route-dependent timing
/// conflicts (a drive overrunning the next Start At) are reported by
/// `RunCompiler` in the preview.
enum RunValidator {
    static let maxWait: Double = 7 * 24 * 3600
    static let maxRepeatTimes = 100
    static let maxExpandedActions = 500

    static func validate(_ run: ScheduledRun, now: Date = Date()) -> [RunIssue] {
        var issues: [RunIssue] = []
        let actions = run.actions

        if actions.isEmpty {
            issues.append(.error("Add at least one action."))
        }

        switch run.schedule {
        case .manual:
            break
        case .once(let date):
            if date < now, run.lastHandledOccurrence == nil {
                issues.append(.warning("The scheduled date has already passed, so this run won't start on its own."))
            }
        case .recurring(_, let weekdays, let tzID):
            if weekdays.isEmpty || !weekdays.allSatisfy({ (1...7).contains($0) }) {
                issues.append(.error("Pick at least one day for the run to repeat on."))
            }
            if let tzID, TimeZone(identifier: tzID) == nil {
                issues.append(.error("Unknown time zone \"\(tzID)\"."))
            }
        }

        if let p = run.defaultSpeed.validationProblem {
            issues.append(.error("Default speed: \(p)"))
        }

        // Location state: unknown = whatever Locus is spoofing when the run starts.
        enum LocState { case runtime, known, none }
        var loc = LocState.runtime
        var warnedRuntimeStart = false
        var lastStartAt: (day: Int, minutes: Int)?

        for (index, action) in actions.enumerated() {
            let id = action.id
            switch action.kind {
            case .setLocation(let place):
                if !place.point.isValid { issues.append(.error("Pick a location.", id)) }
                loc = .known

            case .driveTo(let place, let speed):
                if !place.point.isValid { issues.append(.error("Pick a destination.", id)) }
                if let p = speed?.validationProblem { issues.append(.error(p, id)) }
                switch loc {
                case .none:
                    issues.append(.error("Spoofing was stopped earlier, so there's nowhere to drive from. Add Set Location before this drive.", id))
                case .runtime where !warnedRuntimeStart:
                    issues.append(.warning("Starts from wherever Locus is spoofing when the run begins. Add Set Location first for a predictable start.", id))
                    warnedRuntimeStart = true
                default:
                    break
                }
                loc = .known

            case .wait(let seconds):
                if !seconds.isFinite || seconds <= 0 {
                    issues.append(.error("Wait must be longer than zero.", id))
                } else if seconds > maxWait {
                    issues.append(.error("Wait can't be longer than 7 days.", id))
                }

            case .startAt(let time, let dayOffset):
                if dayOffset < 0 || dayOffset > 6 {
                    issues.append(.error("Start At can be at most 6 days after the run starts.", id))
                }
                let key = (day: dayOffset, minutes: time.minutesSinceMidnight)
                if let last = lastStartAt, (key.day, key.minutes) < (last.day, last.minutes) {
                    issues.append(.error("This time is earlier than a previous Start At step. Reorder the steps or use \"Next day\".", id))
                }
                lastStartAt = key

            case .setSpeed(let policy):
                if let p = policy.validationProblem { issues.append(.error(p, id)) }

            case .stopSpoofing:
                loc = .none

            case .repeatPrevious(let count, let times):
                if count < 1 {
                    issues.append(.error("Choose at least one step to repeat.", id))
                } else if count > index {
                    issues.append(.error("There are only \(index) step\(index == 1 ? "" : "s") before this Repeat.", id))
                } else {
                    let range = actions[(index - count)..<index]
                    if range.contains(where: { $0.kind.category == .repeatPrevious }) {
                        issues.append(.error("A Repeat can't include another Repeat.", id))
                    }
                    if range.contains(where: { $0.kind.category == .startAt }) {
                        issues.append(.warning("Repeated Start At steps won't wait again once their time has passed.", id))
                    }
                }
                if times < 1 || times > maxRepeatTimes {
                    issues.append(.error("Repeat between 1 and \(maxRepeatTimes) times.", id))
                }
            }
        }

        if !issues.hasErrors, (try? RunExpander.expand(actions))?.count ?? 0 > maxExpandedActions {
            issues.append(.error("With repeats this run has more than \(maxExpandedActions) steps. Reduce the repeat count."))
        }
        return issues
    }
}

/// Unrolls Repeat actions into a flat list.
enum RunExpander {
    struct Expanded: Equatable {
        var action: RunAction
        /// 0 for the original pass, 1… for repetitions.
        var iteration: Int
    }

    enum ExpandError: Error, Equatable { case invalidRepeat(UUID) }

    static func expand(_ actions: [RunAction]) throws -> [Expanded] {
        var out: [Expanded] = []
        // Maps original index → index range in `out`, so repeats copy what the
        // preceding *original* actions expanded to.
        var spans: [Range<Int>] = []
        for (index, action) in actions.enumerated() {
            let begin = out.count
            if case .repeatPrevious(let count, let times) = action.kind {
                guard count >= 1, count <= index, times >= 1, times <= RunValidator.maxRepeatTimes else {
                    throw ExpandError.invalidRepeat(action.id)
                }
                let lo = spans[index - count].lowerBound
                let hi = spans[index - 1].upperBound
                let block = Array(out[lo..<hi])
                if block.contains(where: { $0.action.kind.category == .repeatPrevious }) {
                    throw ExpandError.invalidRepeat(action.id)
                }
                for t in 1...times {
                    out.append(contentsOf: block.map { Expanded(action: $0.action, iteration: t) })
                    if out.count > RunValidator.maxExpandedActions * 4 { break }
                }
            } else {
                out.append(Expanded(action: action, iteration: 0))
            }
            spans.append(begin..<out.count)
        }
        return out
    }
}
