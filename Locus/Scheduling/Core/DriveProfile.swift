import Foundation

/// Instantaneous simulated state on a drive.
struct DriveState: Equatable {
    var position: GeoPoint
    /// m/s
    var speed: Double
    /// Degrees clockwise from north.
    var heading: Double
    var distanceTravelled: Double
    var distanceRemaining: Double
    /// Reference ("limit") speed at this point, m/s.
    var referenceSpeed: Double
    var referenceSource: SpeedReferenceSource
    /// Set while standing at a red light or stop sign.
    var stoppedFor: DriveStop.Kind? = nil
}

/// A precomputed time-parameterised drive along a polyline.
///
/// Built once (pure function of route + speed policy + motion settings), then
/// sampled at any elapsed time. Speeds are solved per node with:
///   1. target = policy(reference speed at node)
///   2. corner cap  = sqrt(lateralAccel × turnRadius) at bends
///   3. forward pass (acceleration limit) and backward pass (braking limit),
///      starting from `initialSpeed` and ending stopped at the destination.
/// Between nodes motion is constant-acceleration, so time and distance agree.
struct DriveProfile: Codable, Equatable {
    static let nodeSpacing = 10.0 // metres

    private(set) var polyline: Polyline
    /// Speed at each node, m/s.
    private(set) var nodeSpeeds: [Double]
    /// Cumulative time at each node, seconds.
    private(set) var nodeTimes: [Double]
    private(set) var reference: SpeedReference
    private(set) var policy: SpeedPolicy
    private(set) var motion: MotionSettings
    /// Red lights / stop signs along the route (nil when none).
    private(set) var stops: [DriveStop]?
    /// Seconds stood still at each node before moving on (nil when no stops).
    private(set) var nodeDwell: [Double]?
    /// Kind of stop at each node with a dwell.
    private(set) var nodeStopKind: [DriveStop.Kind?]?
    /// Speed drift along the route (nil = exactly on target).
    private(set) var speedKnots: [SpeedKnot]?

    var duration: Double { nodeTimes.last ?? 0 }
    var distance: Double { polyline.length }
    var referenceSource: SpeedReferenceSource { reference.overallSource(routeLength: distance) }
    var hasPostedLimits: Bool { !reference.spans.isEmpty }
    var maxSpeed: Double { nodeSpeeds.max() ?? 0 }
    var averageSpeed: Double { duration > 0 ? distance / duration : 0 }

    init(
        route: Polyline,
        reference: SpeedReference,
        policy: SpeedPolicy,
        motion: MotionSettings = .standard,
        initialSpeed: Double = 0,
        stops: [DriveStop] = [],
        speedKnots: [SpeedKnot] = []
    ) {
        let line = route.densified(maxSpacing: Self.nodeSpacing)
        let n = line.points.count

        // 1. Targets. Each road segment between nodes has one target; a node
        // takes the lower of the segments on either side so speed changes
        // happen at the boundary (brake before a slower zone, speed up only
        // after entering a faster one).
        let variesSpeed = policy == .variable || (policy.usesReference && motion.realism?.varySpeed == true)
        let zones = (motion.speedZones ?? []).filter(\.isValid).sorted { $0.speed < $1.speed }
        let timeWindow = min(120, max(12, line.length / reference.fallback))
        var cruisingTime = 0.0
        var segTarget = [Double](repeating: 0, count: max(0, n - 1))
        for k in 0..<(n - 1) {
            let mid = (line.cumulative[k] + line.cumulative[k + 1]) / 2
            let point = Geo.interpolate(line.points[k], line.points[k + 1], 0.5)
            if let zone = zones.first(where: { $0.contains(point) }) {
                segTarget[k] = zone.speed
                continue
            }
            let limit = reference.speed(atDistance: mid)
            if case .aboveLimitForTime(let offset, let percent) = policy, !limit.source.isFallback {
                let length = line.cumulative[k + 1] - line.cumulative[k]
                let phase = (cruisingTime + length / (2 * limit.value)).truncatingRemainder(dividingBy: timeWindow)
                // Put the faster stretch in the middle of each cruising window.
                let isAbove = percent >= 100 || abs(phase / timeWindow - 0.5) < percent / 200
                let target = isAbove ? SpeedPolicy.aboveLimit(offset).target(reference: limit.value) : limit.value
                segTarget[k] = target
                cruisingTime += length / target
                continue
            }
            let base = limit.source.isFallback && policy.usesReference
                ? limit.value : policy.target(reference: limit.value)
            let drift = variesSpeed && (!limit.source.isFallback || policy == .variable)
                ? DriveRealismPlanner.factor(speedKnots, atDistance: mid) : 1
            let adjusted = policy == .followLimit ? base * min(1, drift) : base * drift
            segTarget[k] = min(SpeedPolicy.maximumSpeed, max(SpeedPolicy.minimumSpeed, adjusted))
        }
        var v = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let before = i > 0 ? segTarget[i - 1] : Double.infinity
            let after = i < n - 1 ? segTarget[i] : Double.infinity
            v[i] = min(before, after)
        }

        // 2. Corners.
        if motion.slowForTurns && n >= 3 {
            for i in 1..<(n - 1) {
                let h1 = Geo.bearing(line.points[i - 1], line.points[i])
                let h2 = Geo.bearing(line.points[i], line.points[i + 1])
                let theta = Geo.headingDelta(h1, h2) * .pi / 180
                guard theta > 0.035 else { continue } // < 2°: straight enough
                let l1 = line.cumulative[i] - line.cumulative[i - 1]
                let l2 = line.cumulative[i + 1] - line.cumulative[i]
                // Curvature ≈ turn angle / arc length.
                let radius = (l1 + l2) / (2 * theta)
                let cap = max(motion.minimumCornerSpeed, (motion.lateralAcceleration * radius).squareRoot())
                v[i] = min(v[i], cap)
            }
        }

        // 3. Full stops (red lights / stop signs) snap to the nearest inner
        // node; the passes below brake into and pull away from them.
        var dwell = [Double](repeating: 0, count: n)
        var stopKind = [DriveStop.Kind?](repeating: nil, count: n)
        var keptStops: [DriveStop] = []
        if n >= 3 {
            for stop in stops.sorted(by: { $0.distance < $1.distance }) where stop.dwell > 0 {
                guard stop.distance > 0, stop.distance < line.length else { continue }
                let i = Self.nearestNode(line.cumulative, stop.distance)
                guard i > 0, i < n - 1 else { continue }
                v[i] = 0
                dwell[i] += stop.dwell
                stopKind[i] = stopKind[i] == .redLight ? .redLight : stop.kind
                keptStops.append(stop)
            }
        }

        // 4. Endpoints and acceleration limits.
        v[0] = max(0, min(initialSpeed, SpeedPolicy.maximumSpeed))
        v[n - 1] = 0
        if motion.smoothing {
            for i in 1..<n {
                let ds = line.cumulative[i] - line.cumulative[i - 1]
                v[i] = min(v[i], (v[i - 1] * v[i - 1] + 2 * motion.acceleration * ds).squareRoot())
            }
            for i in stride(from: n - 2, through: 0, by: -1) {
                let ds = line.cumulative[i + 1] - line.cumulative[i]
                v[i] = min(v[i], (v[i + 1] * v[i + 1] + 2 * motion.deceleration * ds).squareRoot())
            }
        }

        // 5. Time at each node (departure from node i-1 waits out its dwell).
        var t = [Double](repeating: 0, count: n)
        for i in 1..<n {
            let ds = line.cumulative[i] - line.cumulative[i - 1]
            let avg = max(Self.crawlSpeed, (v[i - 1] + v[i]) / 2)
            t[i] = t[i - 1] + dwell[i - 1] + ds / avg
        }

        self.polyline = line
        self.nodeSpeeds = v
        self.nodeTimes = t
        self.reference = reference
        self.policy = policy
        self.motion = motion
        let hasStops = !keptStops.isEmpty
        self.stops = hasStops ? keptStops : nil
        self.nodeDwell = hasStops ? dwell : nil
        self.nodeStopKind = hasStops ? stopKind : nil
        self.speedKnots = speedKnots.isEmpty ? nil : speedKnots
    }

    private static func nearestNode(_ cumulative: [Double], _ d: Double) -> Int {
        var lo = 0
        var hi = cumulative.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if cumulative[mid] <= d { lo = mid } else { hi = mid }
        }
        return (d - cumulative[lo]) <= (cumulative[hi] - d) ? lo : hi
    }

    /// Total seconds spent standing at lights and signs.
    var totalStopTime: Double { stops?.totalDwell ?? 0 }

    /// The same route, stops and drift re-solved for another speed policy.
    func withPolicy(_ newPolicy: SpeedPolicy) -> DriveProfile {
        DriveProfile(
            route: polyline,
            reference: reference,
            policy: newPolicy,
            motion: motion,
            stops: stops ?? [],
            speedKnots: speedKnots ?? []
        )
    }

    /// Averages below this are treated as linear crawl (avoids divide-by-zero
    /// when a segment both starts and ends stopped).
    private static let crawlSpeed = 0.3

    func state(at elapsed: Double) -> DriveState {
        let n = nodeTimes.count
        let t = min(max(0, elapsed), duration)
        var i = 0
        if t >= duration {
            i = n - 2
        } else {
            var lo = 0
            var hi = n - 1
            while hi - lo > 1 {
                let mid = (lo + hi) / 2
                if nodeTimes[mid] <= t { lo = mid } else { hi = mid }
            }
            i = lo
        }
        if t >= duration {
            let endRef = reference.speed(atDistance: distance)
            return DriveState(
                position: polyline.end,
                speed: 0,
                heading: polyline.heading(atDistance: distance),
                distanceTravelled: distance,
                distanceRemaining: 0,
                referenceSpeed: endRef.value,
                referenceSource: endRef.source
            )
        }
        let wait = nodeDwell?[i] ?? 0
        let sinceNode = t - nodeTimes[i]
        if wait > 0, sinceNode < wait {
            // Standing at a red light / stop sign.
            let d = polyline.cumulative[i]
            let ref = reference.speed(atDistance: d)
            return DriveState(
                position: polyline.point(atDistance: d),
                speed: 0,
                heading: polyline.heading(atDistance: d),
                distanceTravelled: d,
                distanceRemaining: max(0, distance - d),
                referenceSpeed: ref.value,
                referenceSource: ref.source,
                stoppedFor: nodeStopKind?[i] ?? .redLight
            )
        }
        let dt = nodeTimes[i + 1] - nodeTimes[i] - wait
        let ds = polyline.cumulative[i + 1] - polyline.cumulative[i]
        let v0 = nodeSpeeds[i]
        let v1 = nodeSpeeds[i + 1]
        let tau = min(max(0, sinceNode - wait), dt)

        let s: Double
        let speed: Double
        if dt <= 0 {
            s = 0
            speed = v1
        } else if (v0 + v1) / 2 < Self.crawlSpeed {
            s = ds * tau / dt
            speed = ds / dt
        } else {
            let a = (v1 - v0) / dt
            s = min(ds, v0 * tau + 0.5 * a * tau * tau)
            speed = v0 + a * tau
        }
        let d = polyline.cumulative[i] + s
        let ref = reference.speed(atDistance: d)
        return DriveState(
            position: polyline.point(atDistance: d),
            speed: max(0, speed),
            heading: polyline.heading(atDistance: d),
            distanceTravelled: d,
            distanceRemaining: max(0, distance - d),
            referenceSpeed: ref.value,
            referenceSource: ref.source
        )
    }

    /// The rest of this drive from `elapsed`, re-solved with a new policy (or
    /// the same one) and starting at `initialSpeed`. Nil when arrived.
    func remainder(
        from elapsed: Double,
        policy newPolicy: SpeedPolicy? = nil,
        motion newMotion: MotionSettings? = nil,
        initialSpeed: Double? = nil
    ) -> DriveProfile? {
        let s = state(at: elapsed)
        guard let rest = polyline.suffix(fromDistance: s.distanceTravelled) else { return nil }
        let travelled = s.distanceTravelled
        // Stops still ahead keep their place; one we're standing at now is
        // finished early (the car pulls away when resumed).
        let aheadStops = (stops ?? []).compactMap { stop -> DriveStop? in
            let d = stop.distance - travelled
            return d > 1 ? DriveStop(distance: d, dwell: stop.dwell, kind: stop.kind) : nil
        }
        let aheadKnots = (speedKnots ?? []).map { SpeedKnot(distance: $0.distance - travelled, factor: $0.factor) }
        return DriveProfile(
            route: rest,
            reference: reference.shifted(by: travelled),
            policy: newPolicy ?? policy,
            motion: newMotion ?? motion,
            initialSpeed: initialSpeed ?? s.speed,
            stops: aheadStops,
            speedKnots: aheadKnots
        )
    }
}
