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
    @State private var mapRevision = UUID()
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
        let draft = ScheduledRun(name: "Drive to \(destination.name)", defaultSpeed: prefs.speed, motion: prefs.motion)
        _draft = State(initialValue: draft)
        _origin = State(initialValue: origin)
        _stops = State(initialValue: (stops + [destination.placeRef]).map { RunAction(.driveTo($0, speed: nil)) })
        self.onStarted = onStarted
    }

    init(saved route: ScheduledRun, onStarted: @escaping () -> Void) {
        _draft = State(initialValue: route)
        if let first = route.actions.first, case .setLocation(let place) = first.kind {
            _origin = State(initialValue: place)
        }
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
        NavigationStack {
            Form {
                previewSection
                stopsSection
                Section("Route Name") { TextField("Route name", text: $draft.name) }
                Section("Presets") {
                    Picker("Driving preset", selection: preset) {
                        ForEach(Preset.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                SpeedPolicyEditor(policy: $draft.defaultSpeed, unit: runs.unit, referenceSource: nil)
                motionSection
            }
            .environment(\.editMode, $editMode)
            .navigationTitle("Plan a Drive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button(saved ? "Saved" : "Save Route", action: save)
                        .disabled(!hasRoute || saved)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button(action: start) {
                    Label("Start Drive", systemImage: "car.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .locusProminentButton()
                .disabled(!hasRoute || runs.isBusy)
                .padding(12)
                .background(.bar)
            }
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
            .task(id: PreviewRequest(trip: trip, ready: !isRouting && routeError == nil)) {
                saved = false
                preview = nil
                guard !isRouting, routeError == nil else { return }
                let candidate = trip
                let result = await runs.preview(candidate)
                guard !Task.isCancelled else { return }
                preview = result
                previewedTrip = candidate
            }
            .onChange(of: trip.preferredRoutes) { _, _ in mapRevision = UUID() }
        }
    }

    private var previewSection: some View {
        Section {
            if isRouting {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Finding roads…")
                }
            } else if let routeError {
                Label(routeError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                if origin != nil { Button("Try Again") { retry += 1 } }
            } else if let plan = preview?.plan, plan.totalDriveDistance > 0 {
                RoutePreviewMap(plan: plan, current: nil)
                    .id(mapRevision)
                    .frame(height: 210)
                    .clipShape(.rect(cornerRadius: 16))
                let fmt = RunFormat(unit: runs.unit)
                LabeledContent("Distance", value: fmt.distance(plan.totalDriveDistance))
                if let duration = preview?.estimatedDuration {
                    LabeledContent("Simulated travel time", value: RunFormat.eta(duration))
                }
                if alternatives.values.joined().contains(where: \.fromCache) {
                    Label("Using a previously saved road route", systemImage: "arrow.down.circle")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else if let preview {
                Label(preview.error ?? "Choose a destination farther from your starting point.", systemImage: "info.circle")
            } else {
                ProgressView("Updating trip…")
            }
        }
    }

    private var stopsSection: some View {
        Section {
            Button { editingPlace = .origin } label: {
                LabeledContent("From", value: origin?.name ?? "Choose starting point")
            }
            ForEach(stops) { stop in
                if case .driveTo(let place, _) = stop.kind {
                    Button { editingPlace = .stop(stop.id) } label: {
                        LabeledContent(stop.id == stops.last?.id ? "To" : "Stop", value: place.name)
                    }
                    if let options = alternatives[stop.id], options.count > 1 {
                        Picker("Route to \(place.name)", selection: Binding(
                            get: { choices[stop.id, default: 0] }, set: { choices[stop.id] = $0 }
                        )) {
                            ForEach(options.indices, id: \.self) { index in
                                Text(routeLabel(options[index], index: index)).tag(index)
                            }
                        }
                    }
                }
            }
            .onMove { stops.move(fromOffsets: $0, toOffset: $1) }
            .onDelete { if $0.count < stops.count { stops.remove(atOffsets: $0) } }
            Button { editingPlace = .newStop } label: { Label("Add Stop", systemImage: "plus") }
        } header: {
            HStack {
                Text("Stops")
                Spacer()
                if stops.count > 1 { EditButton() }
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

    private enum Preset: String, CaseIterable, Identifiable {
        case normal = "Normal", slow = "Slow", fast = "Fast", custom = "Custom"
        var id: String { rawValue }
    }

    private var preset: Binding<Preset> {
        Binding {
            switch draft.defaultSpeed {
            case .followLimit: return .normal
            case .belowLimit: return .slow
            case .aboveLimit: return .fast
            default: return .custom
            }
        } set: { value in
            let offset = runs.unit.toMetersPerSecond(5)
            switch value {
            case .normal: draft.defaultSpeed = .followLimit
            case .slow: draft.defaultSpeed = .belowLimit(offset)
            case .fast: draft.defaultSpeed = .aboveLimit(offset)
            case .custom: draft.defaultSpeed = .variable
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

    private func routeLabel(_ route: RouteResult, index: Int) -> String {
        let distance = (try? Polyline(sanitizing: route.points).length) ?? 0
        let formatted = RunFormat(unit: runs.unit).distance(distance)
        let eta = route.expectedTravelTime.map { " · \(RunFormat.eta($0))" } ?? ""
        return "Route \(index + 1) · \(formatted)\(eta)"
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
                    if let existing, existing.origin == from, existing.destination == place.point,
                       request.retry == 0 {
                        found[stop.id] = alternatives[stop.id] ?? [existing.route]
                    } else {
                        found[stop.id] = try await runs.routeOptions(from: from, to: place.point)
                    }
                }
                from = place.point
            }
            try Task.checkCancellation()
            choices = choices.filter { id, index in found[id]?.indices.contains(index) == true }
            alternatives = found
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
        route.isSavedRoute = true
        runs.save(route)
        saved = true
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
