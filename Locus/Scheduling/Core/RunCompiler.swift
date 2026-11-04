import Foundation

/// A road-following route from a routing service.
struct RouteResult: Codable, Equatable {
    var points: [GeoPoint]
    /// The service's own ETA in seconds, if it gives one.
    var expectedTravelTime: Double?
    /// Posted limits along the route, if the service provides them.
    /// (Apple MapKit does not; see SpeedReferenceSource.)
    var speedLimits: [SpeedLimitSpan]?
    var providerName: String
    /// Served from the offline cache because live routing failed.
    var fromCache: Bool = false
}

enum RouteProviderError: Error, LocalizedError, Equatable {
    case noRoute
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .noRoute: return "No driving route was found."
        case .unavailable(let message): return message
        }
    }
}

/// Supplies driving routes. The app uses MapKit (`MapKitRouteProvider`);
/// tests use fakes.
protocol RouteProvider: AnyObject {
    func route(from: GeoPoint, to: GeoPoint) async throws -> RouteResult
}

/// Remembers the last good route between two points so a run can still start
/// when routing is offline. Persisted as JSON when `fileURL` is set.
final class RouteCache {
    private var entries: [String: RouteResult] = [:]
    private let fileURL: URL?
    private let maxEntries = 64
    private var order: [String] = []

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: RouteResult].self, from: data) {
            entries = decoded
            order = Array(decoded.keys)
        }
    }

    static func key(_ a: GeoPoint, _ b: GeoPoint) -> String {
        // ~11 m grid so tiny pin differences reuse the same route.
        String(format: "%.4f,%.4f>%.4f,%.4f", a.latitude, a.longitude, b.latitude, b.longitude)
    }

    func lookup(from a: GeoPoint, to b: GeoPoint) -> RouteResult? { entries[Self.key(a, b)] }

    func store(_ route: RouteResult, from a: GeoPoint, to b: GeoPoint) {
        let k = Self.key(a, b)
        var r = route
        r.fromCache = false
        entries[k] = r
        order.removeAll { $0 == k }
        order.append(k)
        while order.count > maxEntries {
            entries.removeValue(forKey: order.removeFirst())
        }
        persist()
    }

    private func persist() {
        guard let fileURL, let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Live routing with an offline fallback to the last good route.
final class CachingRouteProvider: RouteProvider {
    let base: RouteProvider
    let cache: RouteCache

    init(base: RouteProvider, cache: RouteCache) {
        self.base = base
        self.cache = cache
    }

    func route(from: GeoPoint, to: GeoPoint) async throws -> RouteResult {
        do {
            let r = try await base.route(from: from, to: to)
            cache.store(r, from: from, to: to)
            return r
        } catch {
            if var cached = cache.lookup(from: from, to: to) {
                cached.fromCache = true
                return cached
            }
            throw error
        }
    }
}

enum CompileError: Error, LocalizedError, Equatable {
    case invalid([RunIssue])
    case noStartLocation(actionID: UUID)
    case routeFailed(actionID: UUID, destination: String, reason: String)
    case malformedRoute(actionID: UUID, destination: String, reason: String)

    var actionID: UUID? {
        switch self {
        case .invalid(let issues): return issues.first { $0.severity == .error }?.actionID
        case .noStartLocation(let id), .routeFailed(let id, _, _), .malformedRoute(let id, _, _): return id
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalid(let issues):
            return issues.first { $0.severity == .error }?.message ?? "This run has errors."
        case .noStartLocation:
            return "Drive To needs a starting point. Add a Set Location step first, or start spoofing a location before running."
        case .routeFailed(_, let dest, let reason):
            return "Couldn't get a driving route to \(dest): \(reason) Check your connection and try again."
        case .malformedRoute(_, let dest, let reason):
            return "The route to \(dest) is unusable: \(reason)"
        }
    }
}

struct CompileResult {
    var plan: RunPlan
    /// Validation warnings + timing conflicts found while compiling.
    var issues: [RunIssue]
    var estimatedDuration: Double
}

/// Turns a run definition into a timed plan: validates, unrolls repeats,
/// fetches routes, builds drive profiles, resolves Start At times, and
/// reports schedule conflicts (e.g. a drive that overruns the next Start At).
struct RunCompiler {
    var routeProvider: RouteProvider
    /// Below this, Drive To treats origin and destination as the same place.
    static let arrivalTolerance = 15.0
    /// A route whose ends are farther than this from the requested points is rejected.
    static let maxSnapDistance = 2_000.0

    /// - Parameters:
    ///   - anchorDate: the day Start At times are resolved against (the
    ///     scheduled occurrence, or now for a manual run).
    ///   - startDate: when execution begins (≥ anchorDate if started late).
    ///   - currentLocation: what Locus is spoofing now, used when the run's
    ///     first drive has no Set Location before it.
    func compile(
        _ run: ScheduledRun,
        anchorDate: Date,
        startDate: Date,
        currentLocation: GeoPoint?
    ) async throws -> CompileResult {
        var issues = RunValidator.validate(run, now: startDate)
        if case .once = run.schedule {
            // "Date passed" is irrelevant once we're actually running it.
            issues.removeAll { $0.actionID == nil && $0.severity == .warning }
        }
        guard !issues.hasErrors else { throw CompileError.invalid(issues) }

        let expanded = try RunExpander.expand(run.actions)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = run.timeZone

        var segments: [PlanSegment] = []
        var location: GeoPoint? = currentLocation?.isValid == true ? currentLocation : nil
        var policy = run.defaultSpeed
        var cursor = startDate
        var routeMemo: [String: RouteResult] = [:]
        var warnedStartAtIDs = Set<UUID>()

        func append(_ kind: PlanSegment.Kind, _ e: RunExpander.Expanded, at loc: GeoPoint?) {
            segments.append(PlanSegment(id: segments.count, actionID: e.action.id, iteration: e.iteration, kind: kind, location: loc))
        }

        for e in expanded {
            let id = e.action.id
            switch e.action.kind {
            case .setLocation(let place):
                location = place.point
                append(.teleport(place), e, at: place.point)

            case .wait(let seconds):
                append(.hold(seconds: seconds), e, at: location)
                cursor = cursor.addingTimeInterval(seconds)

            case .startAt(let time, let dayOffset):
                let target = Self.resolve(time, dayOffset: dayOffset, anchor: anchorDate, calendar: calendar)
                if target < cursor.addingTimeInterval(-1), !warnedStartAtIDs.contains(id) {
                    let late = cursor.timeIntervalSince(target)
                    let msg: String
                    if segments.contains(where: { $0.fixedDuration > 0 }) {
                        msg = "Earlier steps run \(DurationText.short(late)) past this time, so this step will start late."
                    } else {
                        msg = "This time has already passed (by \(DurationText.short(late))), so it won't wait."
                    }
                    issues.append(.warning(msg, id))
                    warnedStartAtIDs.insert(id)
                }
                append(.waitUntil(target), e, at: location)
                cursor = max(cursor, target)

            case .setSpeed(let p):
                policy = p
                append(.setSpeed(p), e, at: location)

            case .stopSpoofing:
                location = nil
                append(.stop, e, at: nil)

            case .driveTo(let place, let custom):
                guard let from = location else { throw CompileError.noStartLocation(actionID: id) }
                if Geo.distance(from, place.point) < Self.arrivalTolerance {
                    if e.iteration == 0 {
                        issues.append(.warning("Already at \(place.name) — this drive is skipped.", id))
                    }
                    location = place.point
                    continue
                }
                let key = RouteCache.key(from, place.point)
                let route: RouteResult
                if let memo = routeMemo[key] {
                    route = memo
                } else {
                    do {
                        route = try await routeProvider.route(from: from, to: place.point)
                    } catch {
                        let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                        throw CompileError.routeFailed(actionID: id, destination: place.name, reason: reason)
                    }
                    routeMemo[key] = route
                    if route.fromCache {
                        issues.append(.warning("Live routing failed; using the route saved earlier for \(place.name).", id))
                    }
                }
                // The provider's own geometry must be usable on its own…
                let road: Polyline
                do {
                    road = try Polyline(sanitizing: route.points)
                } catch {
                    let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    throw CompileError.malformedRoute(actionID: id, destination: place.name, reason: reason)
                }
                // …and actually connect the two places (MapKit snaps to the
                // nearest road, so allow some slack).
                let gapStart = Geo.distance(from, road.start)
                let gapEnd = Geo.distance(place.point, road.end)
                if max(gapStart, gapEnd) > Self.maxSnapDistance {
                    throw CompileError.malformedRoute(
                        actionID: id,
                        destination: place.name,
                        reason: "the route \(gapStart > gapEnd ? "starts" : "ends") \(RunExecutor.km(max(gapStart, gapEnd))) away from the requested point."
                    )
                }
                // Join the exact origin/destination to the road geometry so the
                // simulated location never jumps.
                let line = (try? Polyline(sanitizing: [from] + road.points + [place.point])) ?? road
                let reference = SpeedReference.make(
                    spans: route.speedLimits.map { Self.offset($0, by: Geo.distance(from, road.start)) },
                    routeDistance: line.length,
                    expectedTravelTime: route.expectedTravelTime,
                    travelModeDefault: TravelDefaults.driveSpeed
                )
                let profile = DriveProfile(route: line, reference: reference, policy: custom ?? policy, motion: run.motion)
                let leg = DriveLeg(
                    destination: place,
                    profile: profile,
                    hasCustomSpeed: custom != nil,
                    routeFromCache: route.fromCache,
                    providerName: route.providerName
                )
                append(.drive(leg), e, at: from)
                cursor = cursor.addingTimeInterval(profile.duration)
                location = line.end

            case .repeatPrevious:
                // Unrolled by RunExpander; never present here.
                break
            }
        }

        let plan = RunPlan(segments: segments, anchorDate: anchorDate, startDate: startDate, timeZoneID: calendar.timeZone.identifier)
        let end = plan.projectedEnd(now: startDate)
        return CompileResult(plan: plan, issues: issues, estimatedDuration: end.timeIntervalSince(startDate))
    }

    /// Wall-clock instant for a Start At step. Uses the next existing time on
    /// DST spring-forward days (02:30 → 03:00) and the first of the two on
    /// fall-back days.
    static func resolve(_ time: TimeOfDay, dayOffset: Int, anchor: Date, calendar: Calendar) -> Date {
        let dayStart = calendar.startOfDay(for: anchor)
        let day = calendar.date(byAdding: .day, value: dayOffset, to: dayStart) ?? dayStart
        let comps = DateComponents(hour: time.hour, minute: time.minute, second: 0)
        return calendar.nextDate(
            after: day.addingTimeInterval(-1),
            matching: comps,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        ) ?? day.addingTimeInterval(Double(time.minutesSinceMidnight * 60))
    }

    /// Shifts provider spans by the length of the joint we prepend.
    private static func offset(_ spans: [SpeedLimitSpan], by d: Double) -> [SpeedLimitSpan] {
        guard d > 0 else { return spans }
        return spans.map { SpeedLimitSpan(fromDistance: $0.fromDistance + d, toDistance: $0.toDistance + d, limit: $0.limit) }
    }
}
