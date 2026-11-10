import MapKit
import SwiftUI

/// Plans a trip and hands the chosen road geometry to the existing run executor.
struct DriveOptionsSheet: View {
    @EnvironmentObject private var runs: ScheduledRunsController
    @Environment(\.dismiss) private var dismiss

    @State private var draft: ScheduledRun
    @State private var origin: PlaceRef?
    @State private var stops: [RunAction]
    @State private var alternatives: [UUID: [RouteResult]] = [:]
    @State private var choices: [UUID: Int] = [:]
    @State private var preview: RunPreview?
    @State private var previewedTrip: ScheduledRun?
    @State private var routedRequest: Request?
    @State private var isRouting = true
    @State private var routeError: String?
    @State private var retry = 0
    @State private var editingPlace: PlaceField?
    @State private var editMode: EditMode = .inactive
    @State private var saved = false
    @State private var position: MapCameraPosition = .automatic
    @State private var panelHeight: CGFloat = 0
    @State private var routeLeg: UUID?
    @State private var showOptions = false
    let onStarted: () -> Void

    private enum PlaceField: Identifiable {
        case origin, stop(UUID), newStop
        var id: String {
            switch self {
            case .origin: return "origin"
            case .newStop: return "new"
            case .stop(let id): return id.uuidString
            }
        }
    }

    private struct Request: Equatable {
        var origin: GeoPoint?
        var stops: [RunAction]
        var retry: Int
    }

    private struct PreviewRequest: Equatable {
        var trip: ScheduledRun
        var ready: Bool
    }

    private var request: Request { Request(origin: origin?.point, stops: stops, retry: retry) }

    init(destination: MapPlace, origin: PlaceRef?, stops: [PlaceRef], prefs: DrivePreferences, onStarted: @escaping () -> Void) {
        var motion = prefs.motion
        motion.realism?.varySpeed = false
        let draft = ScheduledRun(name: "Drive to \(destination.name)", defaultSpeed: prefs.speed, motion: motion)
        _draft = State(initialValue: draft)
        _origin = State(initialValue: origin)
        _stops = State(initialValue: (stops + [destination.placeRef]).map { RunAction(.driveTo($0, speed: nil)) })
        self.onStarted = onStarted
    }

    init(saved route: ScheduledRun, onStarted: @escaping () -> Void) {
        _draft = State(initialValue: route)
        let start: PlaceRef?
        if let first = route.actions.first, case .setLocation(let place) = first.kind { start = place }
        else { start = nil }
        _origin = State(initialValue: start)
        _stops = State(initialValue: route.actions.filter { $0.kind.category == .driveTo })
        self.onStarted = onStarted
    }

    private var trip: ScheduledRun {
        var trip = draft
        let startID = draft.actions.first?.id ?? draft.id
        trip.actions = (origin.map { [RunAction(id: startID, .setLocation($0))] } ?? []) + stops
        var from = origin?.point
        var routes: [UUID: PreferredRoute] = [:]
        for stop in stops {
            guard case .driveTo(let place, _) = stop.kind else { continue }
            if let from, let options = alternatives[stop.id], let option = options[safe: choices[stop.id, default: 0]] {
                routes[stop.id] = PreferredRoute(origin: from, destination: place.point, route: option)
            }
            from = place.point
        }
        trip.preferredRoutes = routes
        return trip
    }

    private var hasRoute: Bool {
        !isRouting && routeError == nil && routedRequest == request && previewedTrip == trip
            && preview?.canRun == true && (preview?.plan?.totalDriveDistance ?? 0) > 0
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                routeMap
                    .safeAreaPadding(.bottom, panelHeight + 12)
                    .ignoresSafeArea(edges: .top)
                VStack(spacing: 10) {
                    header
                    ScrollView {
                        VStack(spacing: 12) {
                            stopsCard
                            routeCards
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: max(150, geometry.size.height * 0.45))
                    if !isRouting, routedRequest == request, routeError == nil, !alternatives.isEmpty {
                        goCard
                    }
                }
                .padding(12)
                .locusGlass(.regular, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panelHeight = $0 }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }
        }
        .sheet(isPresented: $showOptions) { optionsSheet }
        .sheet(item: $editingPlace) { field in
            LocationPickerView(initial: place(for: field)) { place in
                switch field {
                case .origin: origin = place
                case .newStop:
                    stops.insert(RunAction(.driveTo(place, speed: nil)), at: max(0, stops.count - 1))
                case .stop(let id):
                    if let i = stops.firstIndex(where: { $0.id == id }) {
                        stops[i].kind = .driveTo(place, speed: nil)
                    }
                }
            }
        }
        .task(id: request) { await findRoutes(for: request) }
        .task(id: PreviewRequest(trip: trip, ready: routedRequest == request && !isRouting && routeError == nil)) {
            saved = false
            guard routedRequest == request, !isRouting, routeError == nil else { return }
            let candidate = trip
            let result = await runs.preview(candidate)
            guard !Task.isCancelled else { return }
            preview = result
            previewedTrip = candidate
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            Button { showOptions = true } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(LocusRoundButtonStyle())
            .accessibilityLabel("Drive options")
            Spacer(minLength: 0)
            VStack(spacing: 0) {
                Label("Directions", systemImage: "car.fill")
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Button { showOptions = true } label: {
                    Text("Speed and Options")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LocusTheme.accentText)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
            }
            .multilineTextAlignment(.center)
            Spacer(minLength: 0)
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(LocusRoundButtonStyle())
                .accessibilityLabel("Close directions")
        }
    }

    private var routeMap: some View {
        let visibleRoutes = routedRequest == request && !isRouting ? alternatives : [:]
        return Map(position: $position) {
            ForEach(stops) { stop in
                if let options = visibleRoutes[stop.id] {
                    let selected = choices[stop.id, default: 0]
                    ForEach(options.indices.filter { $0 != selected }, id: \.self) { index in
                        MapPolyline(coordinates: options[index].points.map(\.coordinate))
                            .stroke(.blue.opacity(0.45), style: routeStroke(width: 5))
                    }
                    if let option = options[safe: selected] {
                        MapPolyline(coordinates: option.points.map(\.coordinate))
                            .stroke(.blue, style: routeStroke(width: 7))
                    }
                }
            }

            if let leg = activeLeg, let options = visibleRoutes[leg.id], options.count > 1 {
                ForEach(options.indices, id: \.self) { index in
                    let route = options[index]
                    if let line = try? Polyline(sanitizing: route.points), let time = route.expectedTravelTime {
                        let fraction = 0.30 + 0.45 * Double(index) / Double(options.count - 1)
                        let selected = index == choices[leg.id, default: 0]
                        Annotation("Route \(index + 1)", coordinate: line.point(atDistance: line.length * fraction).coordinate) {
                            Button {
                                choices[leg.id] = index
                            } label: {
                                Text(RunFormat.eta(time))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(selected ? Color.white : LocusTheme.accentText)
                                    .padding(.horizontal, 12)
                                    .frame(minWidth: 44, minHeight: 44)
                                    .background(selected ? Color(red: 0, green: 0.37, blue: 0.78) : Color(uiColor: .secondarySystemGroupedBackground),
                                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Route \(index + 1), \(RunFormat.eta(time))")
                            .accessibilityAddTraits(selected ? .isSelected : [])
                        }
                        .annotationTitles(.hidden)
                    }
                }
            }
            if let origin {
                Marker(origin.name, systemImage: "location.fill", coordinate: origin.point.coordinate)
                    .tint(.blue)
            }
            ForEach(stops) { stop in
                if case .driveTo(let place, _) = stop.kind {
                    Marker(place.name, systemImage: stop.id == stops.last?.id ? "flag.checkered" : "mappin",
                           coordinate: place.point.coordinate)
                        .tint(.orange)
                }
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        .mapControls { MapCompass() }
    }

    private func routeStroke(width: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
    }

    private var stopsCard: some View {
        VStack(spacing: 0) {
            stopRow(origin?.name ?? "Choose Starting Point", detail: "From", icon: "location.fill", color: .blue) {
                editingPlace = .origin
            }
            ForEach(stops) { stop in
                if case .driveTo(let place, _) = stop.kind {
                    Divider().padding(.leading, 48)
                    let isDestination = stop.id == stops.last?.id
                    stopRow(place.name, detail: isDestination ? "To" : "Stop",
                            icon: isDestination ? "flag.checkered" : "mappin", color: .orange) {
                        editingPlace = .stop(stop.id)
                    }
                }
            }
            Divider().padding(.leading, 48)
            Button { editingPlace = .newStop } label: {
                Label("Add Stop", systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LocusTheme.accentText)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
        }
        .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func stopRow(_ title: String, detail: String, icon: String, color: Color,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(color.gradient, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                    Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var activeLeg: RunAction? {
        stops.first { $0.id == routeLeg && alternatives[$0.id] != nil }
            ?? stops.last { alternatives[$0.id] != nil }
    }

    @ViewBuilder
    private var routeCards: some View {
        if isRouting || (routedRequest != request && routeError == nil) {
            ProgressView("Finding routes…").frame(minHeight: 44)
        } else if let routeError {
            VStack(spacing: 4) {
                Label(routeError, systemImage: "exclamationmark.triangle").font(.subheadline)
                if origin != nil { Button("Try Again") { retry += 1 }.frame(minHeight: 44) }
            }
        } else if !alternatives.isEmpty {
            if alternatives.count > 1, let activeLeg {
                Picker("Compare Routes To", selection: Binding(
                    get: { activeLeg.id }, set: { routeLeg = $0 }
                )) {
                    ForEach(stops) { stop in
                        if alternatives[stop.id] != nil, case .driveTo(let place, _) = stop.kind {
                            Text(place.name).tag(stop.id)
                        }
                    }
                }
                .frame(minHeight: 44)
            }

            if let activeLeg, let options = alternatives[activeLeg.id], options.count > 1 {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(options.indices, id: \.self) { index in
                            routeChoice(options, index: index, legID: activeLeg.id)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        } else {
            Text("Choose a destination farther from your starting point.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func routeChoice(_ options: [RouteResult], index: Int, legID: UUID) -> some View {
        let route = options[index]
        let chosen = choices[legID, default: 0] == index
        let time = route.expectedTravelTime
        let fastest = time != nil && time == options.compactMap(\.expectedTravelTime).min()
        let distance = (try? Polyline(sanitizing: route.points).length) ?? 0
        return Button {
            choices[legID] = index
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(time.map(RunFormat.eta) ?? "Route \(index + 1)")
                    .font(.headline)
                Text(fastest ? "Fastest · \(RunFormat(unit: runs.unit).distance(distance))"
                     : RunFormat(unit: runs.unit).distance(distance))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let name = route.name {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 160, alignment: .leading)
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: 54)
            .background(chosen ? Color.blue.opacity(0.18) : Color.primary.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private var goCard: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                if previewedTrip == trip, let preview {
                    if let duration = preview.estimatedDuration, let plan = preview.plan {
                        Text(RunFormat.eta(duration)).font(.title2.weight(.bold))
                        Text("\(RunFormat.time(.now.addingTimeInterval(duration))) ETA · \(RunFormat(unit: runs.unit).distance(plan.totalDriveDistance))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Simulated travel time")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(preview.error ?? "This drive is unavailable.").font(.subheadline)
                    }
                } else {
                    ProgressView("Calculating drive…").font(.subheadline)
                }
            }
            Spacer(minLength: 0)
            Button(action: start) {
                Text("GO")
                    .font(.headline.weight(.bold))
                    .padding(.horizontal, 5)
                    .frame(minWidth: 50, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 16))
            .tint(Color(red: 0.06, green: 0.46, blue: 0.20))
            .disabled(!hasRoute || runs.isBusy)
            .accessibilityLabel("Start drive")
        }
        .padding(12)
        .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var optionsSheet: some View {
        NavigationStack {
            Form {
                SpeedPolicyEditor(policy: $draft.defaultSpeed, unit: runs.unit, referenceSource: nil)
                if let plan = preview?.plan, plan.segments.contains(where: { segment in
                    if case .drive(let leg) = segment.kind { return leg.profile.hasPostedLimits }
                    return false
                }) {
                    Section {
                        Link("Speed limits © OpenStreetMap contributors",
                             destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                    }
                }
                SpeedZonesSection(zones: $draft.motion.speedZones, plan: preview?.plan, unit: runs.unit)
                motionSection
                Section("Stops") {
                    ForEach(stops) { stop in
                        if case .driveTo(let place, _) = stop.kind { Text(place.name) }
                    }
                    .onMove { stops.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { if $0.count < stops.count { stops.remove(atOffsets: $0) } }
                    if stops.count > 1 { EditButton() }
                }
                Section("Save Route") {
                    TextField("Route name", text: $draft.name)
                    Button(saved ? "Saved" : "Save Route", action: save).disabled(!hasRoute || saved)
                    if alternatives.values.joined().contains(where: \.fromCache) {
                        Label("Using a previously saved road route", systemImage: "arrow.down.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .environment(\.editMode, $editMode)
            .navigationTitle("Speed and Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { showOptions = false } }
            }
        }
    }

    private var motionSection: some View {
        Section {
            DisclosureGroup("Motion and Traffic") {
                Toggle("Slow for turns", isOn: $draft.motion.slowForTurns)
                Toggle("Smooth acceleration and braking", isOn: $draft.motion.smoothing)
                if draft.motion.smoothing {
                    Stepper("Acceleration \(draft.motion.acceleration, specifier: "%.1f") m/s²",
                            value: $draft.motion.acceleration, in: 0.5...5, step: 0.5)
                    Stepper("Braking \(draft.motion.deceleration, specifier: "%.1f") m/s²",
                            value: $draft.motion.deceleration, in: 0.5...6, step: 0.5)
                }
                Toggle("Simulate red lights", isOn: realism.redLights)
                if realism.wrappedValue.redLights {
                    Picker("Longest wait", selection: realism.maxRedLightWait) {
                        ForEach(DriveRealism.redLightChoices, id: \.self) { Text(RunFormat.duration($0)).tag($0) }
                    }
                }
                Toggle("Simulate stop signs", isOn: realism.stopSigns)
                Text("Traffic stops are simulated from route geometry.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var realism: Binding<DriveRealism> {
        Binding(get: { draft.motion.realism ?? .off }, set: { draft.motion.realism = $0 })
    }

    private func place(for field: PlaceField) -> PlaceRef? {
        if case .origin = field { return origin }
        if case .stop(let id) = field, case .driveTo(let place, _)? = stops.first(where: { $0.id == id })?.kind {
            return place
        }
        return nil
    }

    private func findRoutes(for request: Request) async {
        isRouting = true
        preview = nil
        routeError = nil
        guard var from = request.origin else {
            routeError = "Choose a starting point to find a route."
            isRouting = false
            return
        }
        var found: [UUID: [RouteResult]] = [:]
        do {
            for stop in request.stops {
                guard case .driveTo(let place, _) = stop.kind else { continue }
                if Geo.distance(from, place.point) >= RunCompiler.arrivalTolerance {
                    let existing = draft.preferredRoutes?[stop.id]
                    do {
                        let options = try await runs.routeOptions(from: from, to: place.point)
                        if let existing, existing.origin == from, existing.destination == place.point {
                            var saved = existing.route
                            saved.fromCache = options.allSatisfy(\.fromCache)
                            found[stop.id] = [saved] + options.filter { $0.points != saved.points }
                        } else {
                            found[stop.id] = options
                        }
                    } catch {
                        try Task.checkCancellation()
                        guard let existing, existing.origin == from, existing.destination == place.point else { throw error }
                        var cached = existing.route
                        cached.fromCache = true
                        found[stop.id] = [cached]
                    }
                }
                from = place.point
            }
            try Task.checkCancellation()
            var retained: [UUID: Int] = [:]
            for (id, options) in found {
                if let previous = alternatives[id]?[safe: choices[id, default: 0]],
                   let index = options.firstIndex(where: { $0.points == previous.points }) {
                    retained[id] = index
                }
            }
            choices = retained
            alternatives = found
            let points = found.values.joined().flatMap(\.points)
                + request.stops.compactMap { stop in
                    if case .driveTo(let place, _) = stop.kind { return place.point }
                    return nil
                } + [request.origin].compactMap { $0 }
            let rect = points.reduce(MKMapRect.null) { rect, point in
                let mapPoint = MKMapPoint(point.coordinate)
                return rect.union(MKMapRect(origin: mapPoint, size: MKMapSize(width: 1, height: 1)))
            }
            if !rect.isNull {
                let inset = max(400, max(rect.width, rect.height) * 0.14)
                position = .rect(rect.insetBy(dx: -inset, dy: -inset))
            }
            routedRequest = request
            isRouting = false
        } catch {
            guard !Task.isCancelled else { return }
            routeError = error.localizedDescription
            isRouting = false
        }
    }

    private func save() {
        var route = trip
        route.estimatedDuration = preview?.estimatedDuration
        route.isSavedRoute = true
        saved = runs.save(route)
    }

    private func start() {
        guard hasRoute else { return }
        runs.drivePrefs = DrivePreferences(speed: draft.defaultSpeed, realism: realism.wrappedValue, settings: draft.motion)
        runs.startDrive(trip)
        dismiss()
        onStarted()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

struct SavedRoutesView: View {
    @EnvironmentObject private var runs: ScheduledRunsController
    @Environment(\.dismiss) private var dismiss
    var onPlan: () -> Void
    @State private var selection: ScheduledRun?
    @State private var deletion: ScheduledRun?

    var body: some View {
        NavigationStack {
            List {
                Button {
                    dismiss()
                    onPlan()
                } label: { Label("Plan a New Drive", systemImage: "plus") }
                if runs.savedRoutes.isEmpty {
                    ContentUnavailableView("No Saved Routes", systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                                           description: Text("Choose a destination on the map and save it from the drive planner."))
                }
                ForEach(runs.savedRoutes) { route in
                    Button {
                        selection = route
                    } label: {
                        LabeledContent(route.name, value: "\(route.actions.filter { $0.kind.category == .driveTo }.count) stops")
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { deletion = route }
                    }
                }
            }
            .navigationTitle("Routes")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(item: $selection) { route in
                DriveOptionsSheet(saved: route) {
                    dismiss()
                }
                .presentationDragIndicator(.hidden)
            }
            .confirmationDialog("Delete saved route?", isPresented: Binding(
                get: { deletion != nil }, set: { if !$0 { deletion = nil } }
            )) {
                Button("Delete Route", role: .destructive) {
                    if let deletion { runs.delete(deletion.id) }
                    deletion = nil
                }
            }
        }
    }
}
