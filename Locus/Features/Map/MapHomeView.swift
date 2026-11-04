import MapKit
import SwiftUI

/// The main screen, laid out like Apple Maps: a full map, a few floating
/// controls, and one glass panel at the bottom that holds search, the
/// selected place, and what Locus is doing right now.
struct MapHomeView: View {
    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var pairing: PairingStore
    @EnvironmentObject private var runs: ScheduledRunsController

    @StateObject private var search = PlaceSearchCompleter()
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
    @State private var selected: MapPlace?
    @State private var isDraggingPin = false
    @State private var suppressNextMapTap = false
    @State private var resolvingSearch = false

    @State private var showSettings = false
    @State private var showPlaces = false
    @State private var showScheduledRuns = false
    @State private var showActiveRun = false
    @State private var drivePlace: MapPlace?
    @State private var walkingTo: UUID?
    @State private var importedRoute: [CLLocationCoordinate2D] = []
    @State private var confirmTurnOff = false
    /// Height of the bottom panel, so the map keeps its centre and legal
    /// notice above it.
    @State private var panelHeight: CGFloat = 160

    /// Drive legs of the active run, drawn under the spoof marker.
    private var activeRunLegs: [[CLLocationCoordinate2D]] {
        guard let plan = runs.activePlan else { return [] }
        return plan.segments.compactMap { seg in
            if case .drive(let leg) = seg.kind { return leg.profile.polyline.points.map(\.coordinate) }
            return nil
        }
    }

    private var mapStyle: MapStyle {
        switch session.mapStyleIndex {
        case 1: return .hybrid(elevation: .realistic)
        case 2: return .imagery(elevation: .realistic)
        default: return .standard(elevation: .realistic)
        }
    }

    private var isSearching: Bool { searchFocused || !searchText.isEmpty }

    /// Where distances are measured from: the simulated spot, else real GPS.
    private var here: CLLocationCoordinate2D? { session.simulated ?? session.realCoordinate }

    var body: some View {
        ZStack(alignment: .top) {
            map

            VStack(spacing: 8) {
                topChrome
                Spacer(minLength: 0)
                if session.joystickActive && !isSearching {
                    joystickControls
                }
                HomePanel(
                    searchText: $searchText,
                    searchFocused: $searchFocused,
                    search: search,
                    selected: $selected,
                    resolvingSearch: resolvingSearch,
                    walkingTo: walkingTo,
                    here: here,
                    onPickCompletion: select(completion:),
                    onSubmitSearch: submitSearch,
                    onPickPlace: show(_:),
                    onTeleport: teleport(_:),
                    onDrive: { drivePlace = $0 },
                    onWalk: walk(to:),
                    onTurnOff: {
                        // Only ask when it would also end a run.
                        if runs.isActive { confirmTurnOff = true } else { runs.turnOffLocus(session: session, pairing: pairing) }
                    },
                    onOpenSettings: { showSettings = true },
                    onOpenPlaces: { showPlaces = true },
                    onOpenRuns: { showScheduledRuns = true },
                    onOpenActiveRun: { showActiveRun = true }
                )
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panelHeight = $0 }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: isSearching)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: selected)
        .animation(.snappy, value: session.joystickActive)
        .animation(.snappy, value: runs.isActive)
        .onAppear {
            session.startLocationUpdates()
            search.near = here
        }
        .onChange(of: searchText) { _, value in
            search.near = here
            search.query = value
        }
        .onReceive(NotificationCenter.default.publisher(for: .locusOpenScheduledRuns)) { _ in
            showScheduledRuns = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .locusOpenActiveRun)) { _ in
            showActiveRun = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .locusImportGPX)) { note in
            guard let url = note.object as? URL else { return }
            importGPX(url)
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showPlaces) {
            PlacesView { place in
                showPlaces = false
                show(place)
            }
        }
        .sheet(isPresented: $showScheduledRuns) {
            ScheduledRunsView()
        }
        .sheet(item: $drivePlace) { place in
            DriveOptionsSheet(destination: place, origin: session.isSpoofing ? nil : session.realCoordinate) {
                drivePlace = nil
                selected = nil
            }
            .presentationDetents([.large])
        }
        .fullScreenCover(isPresented: $showActiveRun) {
            ActiveRunView()
        }
        .confirmationDialog("Turn off Locus?", isPresented: $confirmTurnOff, titleVisibility: .visible) {
            Button("End and Turn Off", role: .destructive) {
                runs.turnOffLocus(session: session, pairing: pairing)
            }
        } message: {
            Text("This ends \"\(runs.activeRunName ?? "the run")\" and your iPhone goes back to its real location.")
        }
        .sensoryFeedback(.success, trigger: session.isSpoofing)
        .alert("Follow this route?", isPresented: Binding(get: { !importedRoute.isEmpty }, set: { if !$0 { importedRoute = [] } })) {
            Button("Walk It") { followImported(.walk) }
            Button("Drive It") { followImported(.drive) }
            Button("Cancel", role: .cancel) { importedRoute = [] }
        } message: {
            Text("Locus will move along the imported GPX track.")
        }
    }

    // MARK: Map

    private var map: some View {
        MapReader { proxy in
            Map(position: $position) {
                UserAnnotation()

                if let pin = session.pin, showsPin(pin) {
                    Annotation("", coordinate: pin, anchor: .bottom) {
                        MapDropPin(
                            // The place card has its own close button.
                            selected: false,
                            isDragging: isDraggingPin,
                            onSelect: {
                                searchFocused = false
                                suppressTap()
                                if selected == nil { show(.droppedPin(at: pin)) }
                                lookUpAddressIfNeeded()
                            },
                            onRemove: {
                                suppressTap()
                                session.pin = nil
                                selected = nil
                            },
                            onDragBegan: {
                                searchFocused = false
                                suppressNextMapTap = true
                                isDraggingPin = true
                            },
                            onDragMoved: { globalPoint in
                                if let coord = proxy.convert(globalPoint, from: .global) {
                                    session.pin = coord
                                }
                            },
                            onDragEnded: {
                                isDraggingPin = false
                                if let pin = session.pin { show(.droppedPin(at: pin)) }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                    suppressNextMapTap = false
                                }
                            }
                        )
                    }
                }
                if let sim = session.simulated {
                    Annotation(session.simulatedName ?? "You (simulated)", coordinate: sim) {
                        ZStack {
                            Circle().fill(LocusTheme.accent.opacity(0.25)).frame(width: 44, height: 44)
                            Circle().fill(LocusTheme.accent).frame(width: 16, height: 16)
                                .overlay(Circle().stroke(.white, lineWidth: 3))
                                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                        }
                    }
                }
                ForEach(Array(activeRunLegs.enumerated()), id: \.offset) { _, leg in
                    MapPolyline(coordinates: leg)
                        .stroke(LocusTheme.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                }
            }
            .mapStyle(mapStyle)
            .mapControlVisibility(.hidden)
            // Keep the map's centre and Apple's legal notice above the panel.
            .safeAreaPadding(.bottom, isSearching ? 0 : panelHeight)
            // Global coordinates stay correct with a full-bleed map.
            .onTapGesture(coordinateSpace: .global) { point in
                guard !suppressNextMapTap, !isDraggingPin else { return }
                if searchFocused {
                    searchFocused = false
                    return
                }
                guard let coord = proxy.convert(point, from: .global) else { return }
                session.pin = coord
                show(.droppedPin(at: coord))
                lookUpAddressIfNeeded()
            }
        }
        .ignoresSafeArea()
    }

    /// The drop pin is hidden when it sits under the simulated-location dot.
    private func showsPin(_ pin: CLLocationCoordinate2D) -> Bool {
        guard let sim = session.simulated else { return true }
        return abs(sim.latitude - pin.latitude) > 0.00003 || abs(sim.longitude - pin.longitude) > 0.00003
    }

    private func suppressTap() {
        suppressNextMapTap = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            suppressNextMapTap = false
        }
    }

    // MARK: Floating chrome

    private var topChrome: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                StatusPill(onFixSetup: { showSettings = true })
                Spacer(minLength: 0)
                if !isSearching {
                    mapControls
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .topTrailing)))
                }
            }
        }
        .safeAreaPadding(.top, 4)
    }

    /// Vertical glass stack at the top right, like Apple Maps.
    private var mapControls: some View {
        VStack(spacing: 10) {
            VStack(spacing: 0) {
                Menu {
                    Picker("Map", selection: $session.mapStyleIndex) {
                        Label("Explore", systemImage: "map").tag(0)
                        Label("Hybrid", systemImage: "square.2.layers.3d").tag(1)
                        Label("Satellite", systemImage: "globe.americas.fill").tag(2)
                    }
                } label: {
                    controlGlyph(session.mapStyleIndex == 0 ? "map" : "globe.americas.fill")
                }
                .accessibilityLabel("Map style")

                Divider().frame(width: 28)

                Button(action: goToCurrentLocation) {
                    controlGlyph("location.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show my location")
            }
            .locusGlass(.regular, in: Capsule())

            Button {
                if session.joystickActive {
                    session.stopJoystick()
                } else {
                    session.startJoystick(pairing: pairing)
                }
            } label: {
                controlGlyph("dpad.fill", color: session.joystickActive ? .black : .primary)
                    .background(Circle().fill(session.joystickActive ? LocusTheme.accent : .clear))
            }
            .buttonStyle(.plain)
            .locusGlass(.interactive, in: Circle())
            .accessibilityLabel(session.joystickActive ? "Turn off joystick" : "Joystick")
        }
    }

    private func controlGlyph(_ systemName: String, color: Color = .primary) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(color)
            .frame(width: 46, height: 46)
            .contentShape(Rectangle())
    }

    private var joystickControls: some View {
        HStack(alignment: .bottom) {
            HStack(spacing: 4) {
                ForEach(TravelMode.allCases) { mode in
                    let on = session.travelMode == mode
                    Button {
                        session.travelMode = mode
                    } label: {
                        Image(systemName: mode.icon)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(on ? Color.black : Color.primary)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(on ? LocusTheme.accent : .clear))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(mode.title)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(4)
            .locusGlass(.regular, in: Capsule())

            Spacer(minLength: 8)

            JoystickPad { vector in
                session.updateJoystick(vector: vector)
            }
            .frame(width: 140, height: 140)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: Actions

    private func show(_ place: MapPlace) {
        searchFocused = false
        searchText = ""
        selected = place
        session.pin = place.coordinate
        withAnimation(.easeInOut(duration: 0.45)) {
            position = .region(MKCoordinateRegion(center: place.coordinate, latitudinalMeters: 1400, longitudinalMeters: 1400))
        }
    }

    private func lookUpAddressIfNeeded() {
        guard let place = selected, place.kind == .droppedPin else { return }
        let id = place.id
        Task {
            let found = await PlaceSearchCompleter.address(for: place.coordinate)
            guard selected?.id == id else { return }
            if let found {
                selected?.name = found.name
                selected?.subtitle = found.subtitle
            } else {
                selected?.subtitle = String(format: "%.5f, %.5f", place.coordinate.latitude, place.coordinate.longitude)
            }
        }
    }

    private func select(completion: MKLocalSearchCompletion) {
        resolvingSearch = true
        Task {
            let place = await PlaceSearchCompleter.resolve(completion)
            resolvingSearch = false
            if let place {
                show(place)
            } else {
                session.lastError = "Couldn't find \(completion.title). Check your connection and try again."
            }
        }
    }

    private func submitSearch() {
        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let first = search.results.first {
            select(completion: first)
            return
        }
        resolvingSearch = true
        Task {
            let place = await PlaceSearchCompleter.search(text, near: here)
            resolvingSearch = false
            if let place { show(place) } else { session.lastError = "No results for \"\(text)\"." }
        }
    }

    private func teleport(_ place: MapPlace) {
        let name = place.kind == .droppedPin && place.name == "Dropped Pin" ? nil : place.name
        session.teleport(to: place.coordinate, name: name, pairing: pairing)
        if session.isSpoofing { selected = nil }
    }

    private func walk(to place: MapPlace) {
        guard let start = here else {
            session.lastError = "Locus can't find your location yet. Teleport somewhere first, then walk from there."
            return
        }
        walkingTo = place.id
        Task {
            do {
                let coords = try await RouteBuilder.roadRoute(from: start, to: place.coordinate, mode: .walk)
                walkingTo = nil
                selected = nil
                session.followRoute(coords, mode: .walk, destinationName: place.name, pairing: pairing)
            } catch {
                walkingTo = nil
                session.lastError = "Couldn't find a walking route to \(place.name)."
            }
        }
    }

    /// Centers on the simulated spot while spoofing, otherwise real GPS.
    private func goToCurrentLocation() {
        searchFocused = false
        withAnimation(.easeInOut(duration: 0.4)) {
            if let c = here {
                position = .region(MKCoordinateRegion(center: c, latitudinalMeters: 900, longitudinalMeters: 900))
            } else {
                position = .userLocation(fallback: .automatic)
            }
        }
    }

    private func importGPX(_ url: URL) {
        do {
            let coords = try GPXCodec.parse(url)
            importedRoute = RouteBuilder.sample(coordinates: coords, every: 10)
            if let first = coords.first {
                position = .region(MKCoordinateRegion(center: first, latitudinalMeters: 2000, longitudinalMeters: 2000))
            }
        } catch {
            session.lastError = error.localizedDescription
        }
    }

    private func followImported(_ mode: TravelMode) {
        let route = importedRoute
        importedRoute = []
        session.followRoute(route, mode: mode, destinationName: "the end of the route", pairing: pairing)
    }
}
