import MapKit
import NetworkExtension
import SwiftUI

/// The glass panel at the bottom of the map. Shows one of three things:
/// search (with suggestions), the selected place's card, or the home view
/// (what Locus is doing now + favorites).
struct HomePanel: View {
    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var runs: ScheduledRunsController

    @Binding var searchText: String
    var searchFocused: FocusState<Bool>.Binding
    @ObservedObject var search: PlaceSearchCompleter
    @Binding var selected: MapPlace?
    var resolvingSearch: Bool
    var walkingTo: UUID?
    var here: CLLocationCoordinate2D?

    var onPickCompletion: (MKLocalSearchCompletion) -> Void
    var onSubmitSearch: () -> Void
    var onPickPlace: (MapPlace) -> Void
    var onTeleport: (MapPlace) -> Void
    var onDrive: (MapPlace) -> Void
    var onWalk: (MapPlace) -> Void
    var onTurnOff: () -> Void
    var onOpenSettings: () -> Void
    var onOpenPlaces: () -> Void
    var onOpenRuns: () -> Void
    var onOpenActiveRun: () -> Void

    private let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)

    private var isSearching: Bool { searchFocused.wrappedValue || !searchText.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            if let place = selected, !isSearching {
                PlaceCard(
                    place: place,
                    here: here,
                    isWalkLoading: walkingTo == place.id,
                    onClose: {
                        selected = nil
                        // Leave no stray pin behind (one on the simulated dot is hidden).
                        session.pin = session.simulated
                    },
                    onTeleport: { onTeleport(place) },
                    onDrive: { onDrive(place) },
                    onWalk: { onWalk(place) }
                )
                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
            } else {
                searchRow
                    .padding(.horizontal, 14)
                if isSearching {
                    searchResults
                        .transition(.opacity)
                } else {
                    homeContent
                        .transition(.opacity)
                }
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
        .locusGlass(.regular, in: shape)
        .contentShape(shape)
    }

    // MARK: Search

    private var searchRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("Search for a place or address", text: $searchText)
                    .font(.body)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .focused(searchFocused)
                    .submitLabel(.search)
                    .onSubmit(onSubmitSearch)
                if resolvingSearch {
                    ProgressView().controlSize(.small)
                } else if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 46)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.09)))

            if isSearching {
                Button("Cancel") {
                    searchText = ""
                    searchFocused.wrappedValue = false
                }
                .font(.body)
                .foregroundStyle(LocusTheme.accent)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 46, height: 46)
                        .background(Circle().fill(Color.primary.opacity(0.09)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
            }
        }
    }

    private var searchResults: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if searchText.isEmpty {
                    if !session.recents.isEmpty {
                        sectionHeader("Recents")
                        ForEach(session.recents.prefix(8)) { place in
                            resultRow(title: place.name, subtitle: nil, icon: PlaceIcon(kind: .recent, size: 36)) {
                                onPickPlace(MapPlace(saved: place, kind: .recent))
                            }
                        }
                    } else {
                        Text("Search for a café, a city, or a street address.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 14)
                    }
                } else if search.results.isEmpty {
                    if search.isLoading {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Searching…")
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("No Results")
                                .font(.headline)
                            Text("Check the spelling or try a nearby city or street.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                    }
                } else {
                    ForEach(search.results.prefix(12), id: \.self) { item in
                        resultRow(title: item.title, subtitle: item.subtitle.isEmpty ? nil : item.subtitle, icon: PlaceIcon(size: 36)) {
                            onPickCompletion(item)
                        }
                    }
                }
            }
            .padding(.top, 6)
        }
        .scrollDismissesKeyboard(.immediately)
        .frame(maxHeight: .infinity)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    private func resultRow(title: String, subtitle: String?, icon: PlaceIcon, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelRowButtonStyle())
        .overlay(alignment: .bottom) {
            Divider().padding(.leading, 64)
        }
    }

    // MARK: Home

    private var homeContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            NowCard(onTurnOff: onTurnOff, onOpenActiveRun: onOpenActiveRun)
                .padding(.horizontal, 14)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    shortcut(title: "Scheduled", symbol: "calendar.badge.clock", color: LocusTheme.accent, action: onOpenRuns)
                    ForEach(session.favorites.prefix(10)) { fav in
                        shortcut(title: fav.name, symbol: Self.favoriteSymbol(fav.name), color: Color(red: 1.0, green: 0.75, blue: 0.2)) {
                            onPickPlace(MapPlace(saved: fav, kind: .favorite))
                        }
                    }
                    if session.favorites.isEmpty {
                        shortcut(title: "Add", symbol: "plus", color: Color(white: 0.45)) {
                            searchFocused.wrappedValue = true
                        }
                        .accessibilityHint("Search for a place, then tap the star to save it here")
                    } else {
                        shortcut(title: "All", symbol: "ellipsis", color: Color(white: 0.45), action: onOpenPlaces)
                            .accessibilityLabel("All saved places")
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.top, 12)
    }

    private func shortcut(title: String, symbol: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(color.gradient))
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(width: 68)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelRowButtonStyle())
    }

    static func favoriteSymbol(_ name: String) -> String {
        let n = name.lowercased()
        if n.contains("home") || n.contains("house") { return "house.fill" }
        if n.contains("work") || n.contains("office") { return "briefcase.fill" }
        if n.contains("school") || n.contains("college") { return "graduationcap.fill" }
        if n.contains("gym") { return "dumbbell.fill" }
        return "star.fill"
    }
}

/// What Locus is doing right now, with the one button everyone looks for:
/// Turn Off. Hidden while your iPhone is at its real location.
private struct NowCard: View {
    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var runs: ScheduledRunsController
    var onTurnOff: () -> Void
    var onOpenActiveRun: () -> Void

    var body: some View {
        if runs.isActive {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let s = runs.liveSnapshot()
                card(
                    symbol: s?.status == .paused ? "pause.fill" : "car.fill",
                    color: s?.status == .paused ? LocusTheme.statusWarn : LocusTheme.accent,
                    title: runs.activeRunName ?? "Run in progress",
                    subtitle: s?.status == .paused ? (s?.pauseReason ?? "Paused") : ActiveRunBanner.subtitle(s),
                    onTap: onOpenActiveRun
                )
            }
        } else if session.status.isDropped {
            card(symbol: "exclamationmark.triangle.fill", color: LocusTheme.statusBad,
                 title: "Connection lost", subtitle: "Reconnecting automatically. Check LocalDevVPN.", onTap: nil)
        } else if session.joystickActive {
            card(symbol: "dpad.fill", color: LocusTheme.accent,
                 title: "Joystick", subtitle: "\(session.travelMode.title) speed · drag the pad to move", onTap: nil)
        } else if let dest = session.followingRouteTo {
            card(symbol: "figure.walk", color: LocusTheme.accent,
                 title: "Walking to \(dest)", subtitle: "Other apps see you moving", onTap: nil)
        } else if session.isSpoofing || session.status == .connecting {
            card(symbol: "location.fill", color: LocusTheme.accent,
                 title: session.simulatedName ?? "Simulated location",
                 subtitle: session.status == .connecting ? "Connecting…" : "Other apps see you here", onTap: nil)
        }
    }

    private func card(symbol: String, color: Color, title: String, subtitle: String, onTap: (() -> Void)?) -> some View {
        HStack(spacing: 12) {
            Button {
                onTap?()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: symbol)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(color.gradient))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if onTap != nil {
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(onTap == nil)
            .accessibilityElement(children: .combine)

            Button(action: onTurnOff) {
                Text("Turn Off")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 36)
                    .background(Capsule().fill(LocusTheme.danger))
                    .frame(minHeight: 44)
                    .contentShape(Capsule())
            }
            .buttonStyle(PanelRowButtonStyle())
            .accessibilityLabel("Turn off Locus and return to your real location")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.primary.opacity(0.07)))
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }
}

/// The selected place: name, distance and address, then the three ways to
/// get there.
private struct PlaceCard: View {
    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var runs: ScheduledRunsController

    let place: MapPlace
    let here: CLLocationCoordinate2D?
    let isWalkLoading: Bool
    let onClose: () -> Void
    let onTeleport: () -> Void
    let onDrive: () -> Void
    let onWalk: () -> Void

    private var savedID: String { SavedPlace(name: "", latitude: place.coordinate.latitude, longitude: place.coordinate.longitude).id }
    private var isFavorite: Bool { session.favorites.contains { $0.id == savedID } }

    private var detail: String {
        var parts: [String] = []
        if let here {
            let meters = Geo.distance(GeoPoint(here), GeoPoint(place.coordinate))
            if meters > 30 { parts.append(RunFormat(unit: runs.unit).distance(meters)) }
        }
        if !place.subtitle.isEmpty { parts.append(place.subtitle) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                PlaceIcon(category: place.category, kind: place.kind, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(place.name)
                        .font(.title2.weight(.bold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 4)
                circleButton(isFavorite ? "star.fill" : "star", tint: isFavorite ? Color(red: 1.0, green: 0.75, blue: 0.2) : .primary) {
                    if isFavorite {
                        if let fav = session.favorites.first(where: { $0.id == savedID }) { session.removeFavorite(fav) }
                    } else {
                        session.addFavorite(name: place.name, coordinate: place.coordinate)
                    }
                }
                .accessibilityLabel(isFavorite ? "Remove from favorites" : "Add to favorites")
                .sensoryFeedback(.success, trigger: isFavorite)
                circleButton("xmark", tint: .secondary, action: onClose)
                    .accessibilityLabel("Close")
            }

            HStack(spacing: 8) {
                actionButton("Teleport", symbol: "location.fill", prominent: true, action: onTeleport)
                    .disabled(session.isBusy)
                actionButton("Drive", symbol: "car.fill", action: onDrive)
                actionButton("Walk", symbol: "figure.walk", loading: isWalkLoading, action: onWalk)
            }
        }
        .padding(.horizontal, 16)
    }

    private func circleButton(_ symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.primary.opacity(0.1)))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(PanelRowButtonStyle())
    }

    private func actionButton(_ title: String, symbol: String, prominent: Bool = false, loading: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                if loading {
                    ProgressView().frame(height: 22)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 19, weight: .semibold))
                        .frame(height: 22)
                }
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(prominent ? Color.black : LocusTheme.accent)
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(prominent ? LocusTheme.accent : LocusTheme.accent.opacity(0.16))
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PanelRowButtonStyle())
        .disabled(loading)
    }
}

/// Gentle press feedback for panel rows and buttons.
struct PanelRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

/// Small capsule at the top of the map: real or simulated, and a nudge when
/// something needs fixing.
struct StatusPill: View {
    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var pairing: PairingStore
    @Environment(\.scenePhase) private var scenePhase
    var onFixSetup: () -> Void

    @State private var tunnelConnected = LocalDevVPN.isConnected

    private enum Display {
        case needsSetup, connectVPN, real, simulated, busy(String), lost
    }

    private var display: Display {
        switch session.status {
        case .idle:
            if !pairing.hasPairingFile { return .needsSetup }
            return tunnelConnected ? .real : .connectVPN
        case .connecting: return .busy("Connecting…")
        case .active: return .simulated
        case .reconnecting: return .busy("Reconnecting…")
        case .dropped: return .lost
        }
    }

    var body: some View {
        content
            .onAppear { tunnelConnected = LocalDevVPN.isConnected }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { tunnelConnected = LocalDevVPN.isConnected }
            }
            .onChange(of: session.status) { _, _ in tunnelConnected = LocalDevVPN.isConnected }
            .onReceive(NotificationCenter.default.publisher(for: .NEVPNStatusDidChange)) { _ in
                tunnelConnected = LocalDevVPN.isConnected
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    tunnelConnected = LocalDevVPN.isConnected
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch display {
        case .needsSetup:
            pill("Finish Setup", color: LocusTheme.statusWarn, chevron: true)
                .onTapGesture(perform: onFixSetup)
                .accessibilityAddTraits(.isButton)
        case .connectVPN:
            pill("Connect LocalDevVPN", color: LocusTheme.statusWarn, chevron: true)
                .onTapGesture(perform: LocalDevVPN.openOrInstall)
                .accessibilityAddTraits(.isButton)
        case .real:
            pill("Real Location", color: Color.secondary, chevron: false)
        case .simulated:
            pill("Simulated Location", color: LocusTheme.statusGood, chevron: false)
        case .busy(let text):
            pill(text, color: LocusTheme.statusWarn, chevron: false)
        case .lost:
            pill("Connection Lost", color: LocusTheme.statusBad, chevron: false)
        }
    }

    private func pill(_ text: String, color: Color, chevron: Bool) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 34)
        .locusGlass(.regular, in: Capsule())
        .frame(minHeight: 44)
        .contentShape(Capsule())
        .accessibilityElement(children: .combine)
    }
}
