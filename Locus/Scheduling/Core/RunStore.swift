import Foundation

/// A finished (or missed) run, shown in Run History.
struct RunRecord: Codable, Equatable, Identifiable {
    enum Outcome: String, Codable {
        case completed, failed, cancelled, missed

        var label: String {
            switch self {
            case .completed: return "Completed"
            case .failed: return "Failed"
            case .cancelled: return "Cancelled"
            case .missed: return "Missed"
            }
        }
    }

    var id: UUID
    var runID: UUID
    var runName: String
    var trigger: RunTrigger
    var occurrence: Date?
    var outcome: Outcome
    var startedAt: Date?
    var endedAt: Date
    var message: String?
    var distance: Double
    var log: [ExecutionLogEntry]

    init(finished state: ExecutionState, endedAt: Date) {
        id = state.recordID
        runID = state.runID
        runName = state.runName
        trigger = state.trigger
        occurrence = state.occurrence
        switch state.status {
        case .completed: outcome = .completed
        case .cancelled: outcome = .cancelled
        default: outcome = .failed
        }
        startedAt = state.startedAt
        self.endedAt = state.endedAt ?? endedAt
        message = state.failure
        distance = state.distanceBanked
        log = state.log
    }

    init(id: UUID = UUID(), runID: UUID, runName: String, trigger: RunTrigger, occurrence: Date?, outcome: Outcome,
         startedAt: Date?, endedAt: Date, message: String?, distance: Double = 0, log: [ExecutionLogEntry] = []) {
        self.id = id
        self.runID = runID
        self.runName = runName
        self.trigger = trigger
        self.occurrence = occurrence
        self.outcome = outcome
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.message = message
        self.distance = distance
        self.log = log
    }

    func diagnosticsText(timeZone: TimeZone = .current) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = timeZone
        f.formatOptions = [.withInternetDateTime]
        var lines = [
            "Run: \(runName) [\(runID.uuidString)]",
            "Record: \(id.uuidString)",
            "Outcome: \(outcome.label)\(message.map { " — \($0)" } ?? "")",
            "Trigger: \(trigger.rawValue)",
        ]
        if let occurrence { lines.append("Scheduled for: \(f.string(from: occurrence))") }
        if let startedAt { lines.append("Started: \(f.string(from: startedAt))") }
        lines.append("Ended: \(f.string(from: endedAt))")
        lines.append(String(format: "Simulated distance: %.0f m", distance))
        lines.append("Log:")
        for e in log {
            lines.append("  \(f.string(from: e.date)) [\(e.level.rawValue)] \(e.message)")
        }
        return lines.joined(separator: "\n")
    }
}

/// JSON-file persistence for runs, history, and the active-run checkpoint.
///
/// Writes are atomic. A file that fails to decode is moved aside (never
/// silently overwritten) and reported through `problems`.
final class ScheduledRunStore {
    let directory: URL
    private(set) var problems: [String] = []
    static let maxHistory = 100

    private var runsURL: URL { directory.appendingPathComponent("runs.json") }
    private var historyURL: URL { directory.appendingPathComponent("history.json") }
    private var checkpointURL: URL { directory.appendingPathComponent("active-run.json") }
    var routeCacheURL: URL { directory.appendingPathComponent("route-cache.json") }

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Application Support/ScheduledRuns
    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ScheduledRuns", isDirectory: true)
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try Self.decoder().decode(T.self, from: data)
        } catch {
            let aside = url.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: url, to: aside)
            problems.append("\(url.lastPathComponent) couldn't be read and was set aside as \(aside.lastPathComponent).")
            return nil
        }
    }

    @discardableResult
    private func write<T: Encodable>(_ value: T, to url: URL) -> Bool {
        do {
            let data = try Self.encoder().encode(value)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            let problem = "Couldn't save \(url.lastPathComponent): \(error.localizedDescription)"
            if !problems.contains(problem) { problems.append(problem) }
            return false
        }
    }

    func loadRuns() -> [ScheduledRun] { read([ScheduledRun].self, from: runsURL) ?? [] }
    @discardableResult func saveRuns(_ runs: [ScheduledRun]) -> Bool { write(runs, to: runsURL) }

    func loadHistory() -> [RunRecord] { read([RunRecord].self, from: historyURL) ?? [] }
    @discardableResult func saveHistory(_ records: [RunRecord]) -> Bool {
        write(Array(records.prefix(Self.maxHistory)), to: historyURL)
    }

    func loadCheckpoint() -> ExecutionState? { read(ExecutionState.self, from: checkpointURL) }
    func saveCheckpoint(_ state: ExecutionState?) {
        if let state {
            write(state, to: checkpointURL)
        } else {
            try? FileManager.default.removeItem(at: checkpointURL)
        }
    }

    func clearProblems() { problems.removeAll() }
}
