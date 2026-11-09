import MapKit
import SwiftUI

/// Timeline of every step with projected clock times, plus a route map.
struct RunTimelineView: View {
    let preview: RunPreview
    let timeZone: TimeZone
    let unit: SpeedUnit

    var body: some View {
        List {
            if let plan = preview.plan {
                Section {
                    RoutePreviewMap(plan: plan, current: nil)
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                }
                Section {
                    ForEach(plan.segments.indices, id: \.self) { i in
                        TimelineRow(
                            segment: plan.segments[i],
                            projected: i < preview.projected.count ? preview.projected[i] : nil,
                            timeZone: timeZone,
                            unit: unit,
                            phase: .upcoming
                        )
                    }
                } header: {
                    Text("Starting \(RunFormat.dayAndTime(preview.startDate, timeZone: timeZone))")
                } footer: {
                    if let d = preview.estimatedDuration {
                        Text("Total \(RunFormat.duration(d)). Times are estimates; drive times come from Locus's speed simulation, not Apple Maps' traffic ETA.")
                    }
                }
            }
        }
        .navigationTitle("Timeline")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct TimelineRow: View {
    enum Phase { case done, current, upcoming }

    let segment: PlanSegment
    let projected: ProjectedSegment?
    let timeZone: TimeZone
    let unit: SpeedUnit
    let phase: Phase

    private var category: RunActionKind.Category {
        switch segment.kind {
        case .teleport: return .setLocation
        case .hold: return .wait
        case .waitUntil: return .startAt
        case .drive: return .driveTo
        case .setSpeed: return .setSpeed
        case .stop: return .stopSpoofing
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(projected.map { RunFormat.time($0.start, timeZone: timeZone) } ?? "")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
                .padding(.top, 6)
            ActionGlyph(category: category, size: 28)
                .opacity(phase == .done ? 0.4 : 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(summary).font(.subheadline.weight(phase == .current ? .bold : .semibold))
                    if segment.iteration > 0 {
                        Text("#\(segment.iteration + 1)").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                    }
                }
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                if let p = projected, p.lateBy > 60 {
                    Label("Starts \(RunFormat.duration(p.lateBy)) late", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(LocusTheme.statusWarn)
                }
            }
            .opacity(phase == .done ? 0.5 : 1)
            Spacer(minLength: 0)
            if phase == .current {
                Image(systemName: "play.fill").font(.caption).foregroundStyle(LocusTheme.accent)
            } else if phase == .done {
                Image(systemName: "checkmark").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var summary: String {
        let fmt = RunFormat(unit: unit)
        switch segment.kind {
        case .teleport(let p): return "Teleport · \(p.name)"
        case .hold(let s): return "Wait \(RunFormat.duration(s))"
        case .waitUntil(let d): return "Start at \(RunFormat.time(d, timeZone: timeZone))"
        case .drive(let leg): return "Drive to \(leg.destination.name) · \(fmt.distance(leg.profile.distance))"
        case .setSpeed(let p): return "Speed: \(p.summary(unit: unit))"
        case .stop: return "Turn off Locus"
        }
    }

    private var detail: String? {
        guard let p = projected else { return nil }
        let fmt = RunFormat(unit: unit)
        switch segment.kind {
        case .drive(let leg):
            var parts = ["\(RunFormat.time(p.start, timeZone: timeZone))–\(RunFormat.time(p.end, timeZone: timeZone))",
                         "avg \(fmt.speed(leg.profile.averageSpeed))",
                         "max \(fmt.speed(leg.profile.maxSpeed))"]
            if leg.profile.referenceSource.isFallback { parts.append("limits estimated") }
            if leg.routeFromCache { parts.append("saved route") }
            return parts.joined(separator: " · ")
        case .hold, .waitUntil:
            let d = p.end.timeIntervalSince(p.start)
            return d > 0 ? "until \(RunFormat.time(p.end, timeZone: timeZone)) (\(RunFormat.duration(d)))" : nil
        default:
            return nil
        }
    }
}

/// Map of every drive in a plan, with an optional live vehicle marker.
struct RoutePreviewMap: View {
    let plan: RunPlan
    let current: GeoPoint?
    var heading: Double?
    var followsLocation = false
    @State private var position: MapCameraPosition = .automatic

    private var legs: [DriveLeg] {
        plan.segments.compactMap { if case .drive(let l) = $0.kind { return l } else { return nil } }
    }

    private var stops: [PlaceRef] {
        var seen = Set<String>()
        var out: [PlaceRef] = []
        for s in plan.segments {
            let place: PlaceRef?
            switch s.kind {
            case .teleport(let p): place = p
            case .drive(let l): place = l.destination
            default: place = nil
            }
            if let place, seen.insert(RouteCache.key(place.point, place.point)).inserted { out.append(place) }
        }
        return out
    }

    var body: some View {
        Map(position: $position) {
            ForEach(Array(legs.enumerated()), id: \.offset) { _, leg in
                MapPolyline(coordinates: leg.profile.polyline.points.map(\.coordinate))
                    .stroke(RunsStyle.color(.driveTo), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            ForEach(Array(stops.enumerated()), id: \.offset) { _, p in
                Marker(p.name, systemImage: "mappin", coordinate: p.point.coordinate)
                    .tint(LocusTheme.accent)
            }
            if let current {
                Annotation("Simulated", coordinate: current.coordinate) {
                    VehicleMarker(heading: heading)
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .mapControlVisibility(.hidden)
        .onChange(of: current, initial: true) { _, location in
            guard followsLocation, let location, !position.positionedByUser else { return }
            follow(location)
        }
        .overlay(alignment: .topTrailing) {
            if followsLocation, position.positionedByUser, let current {
                Button { follow(current) } label: {
                    Image(systemName: "location.fill").frame(width: 48, height: 48)
                }
                .buttonStyle(.plain)
                .locusGlass(.interactive, in: Circle())
                .accessibilityLabel("Follow simulated location")
                .padding(.trailing, 16)
                .padding(.top, 100)
            }
        }
    }

    private func follow(_ point: GeoPoint) {
        withAnimation(.easeOut(duration: 0.35)) {
            position = .camera(MapCamera(centerCoordinate: point.coordinate, distance: 1400))
        }
    }
}

/// Distinct marker for the simulated vehicle (never the blue GPS dot).
struct VehicleMarker: View {
    var heading: Double?

    var body: some View {
        ZStack {
            Circle().fill(LocusTheme.accentSecondary.opacity(0.25)).frame(width: 40, height: 40)
            Circle().fill(LocusTheme.accentSecondary).frame(width: 24, height: 24)
                .overlay(Circle().stroke(.white, lineWidth: 2))
            Image(systemName: heading == nil ? "car.fill" : "location.north.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .rotationEffect(.degrees(heading ?? 0))
        }
        .accessibilityLabel("Simulated vehicle")
    }
}
