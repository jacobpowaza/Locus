import MapKit
import SwiftUI

/// Pick a place by tapping the map, searching, or from favorites/recents.
struct LocationPickerView: View {
    let initial: PlaceRef?
    let onPick: (PlaceRef) -> Void

    @EnvironmentObject private var session: SpoofSession
    @Environment(\.dismiss) private var dismiss
    @StateObject private var search = PlaceSearchCompleter()

    @State private var position: MapCameraPosition = .automatic
    @State private var picked: PlaceRef?
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                MapReader { proxy in
                    Map(position: $position) {
                        UserAnnotation()
                        if let p = picked {
                            Marker(p.name, systemImage: "mappin", coordinate: p.point.coordinate)
                                .tint(LocusTheme.accent)
                        }
                        if let sim = session.simulated {
                            Annotation("Spoofed", coordinate: sim) {
                                Circle().fill(LocusTheme.accentSecondary).frame(width: 12, height: 12)
                                    .overlay(Circle().stroke(.white, lineWidth: 2))
                            }
                        }
                    }
                    .mapControls { MapCompass() }
                    .onTapGesture { point in
                        searchFocused = false
                        if let c = proxy.convert(point, from: .local) {
                            let name = session.suggestedFavoriteName(for: c)
                            withAnimation(.snappy) { picked = PlaceRef(name: name, point: GeoPoint(c)) }
                        }
                    }
                }
                .frame(minHeight: 260)
                .overlay(alignment: .top) { searchBar.padding(12) }

                List {
                    if !query.isEmpty && !search.results.isEmpty {
                        Section("Results") {
                            ForEach(search.results.prefix(6), id: \.self) { item in
                                Button { select(item) } label: {
                                    VStack(alignment: .leading) {
                                        Text(item.title).foregroundStyle(.primary)
                                        if !item.subtitle.isEmpty {
                                            Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    Section {
                        if let sim = session.simulated {
                            quickRow("Current spoofed location", icon: "location.viewfinder", coord: sim)
                        }
                        if let real = session.realCoordinate {
                            quickRow("My real location", icon: "location.fill", coord: real)
                        }
                        if let pin = session.pin, pin.latitude != session.simulated?.latitude {
                            quickRow("Dropped pin", icon: "mappin", coord: pin)
                        }
                    }
                    if !session.favorites.isEmpty {
                        Section("Favorites") {
                            ForEach(session.favorites) { place in
                                placeRow(PlaceRef(place), icon: "star.fill")
                            }
                        }
                    }
                    if !session.recents.isEmpty {
                        Section("Recents") {
                            ForEach(session.recents.prefix(8)) { place in
                                placeRow(PlaceRef(place), icon: "clock")
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle("Choose Place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use") {
                        if let picked { onPick(picked) }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(picked == nil)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let p = picked {
                    HStack {
                        Image(systemName: "mappin.circle.fill").foregroundStyle(LocusTheme.accent)
                        VStack(alignment: .leading) {
                            Text(p.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(String(format: "%.5f, %.5f", p.point.latitude, p.point.longitude))
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .locusGlass(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal, 12)
                }
            }
            .onAppear {
                picked = initial
                if let c = initial?.point.coordinate ?? session.simulated ?? session.realCoordinate {
                    position = .region(MKCoordinateRegion(center: c, latitudinalMeters: 3000, longitudinalMeters: 3000))
                }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search places", text: $query)
                .focused($searchFocused)
                .submitLabel(.search)
                .onChange(of: query) { _, v in search.query = v }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(10)
        .locusGlass(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func quickRow(_ title: String, icon: String, coord: CLLocationCoordinate2D) -> some View {
        Button {
            pick(PlaceRef(name: session.suggestedFavoriteName(for: coord, fallback: nil), point: GeoPoint(coord)))
        } label: {
            Label(title, systemImage: icon)
        }
    }

    private func placeRow(_ place: PlaceRef, icon: String) -> some View {
        Button { pick(place) } label: {
            Label {
                Text(place.name).foregroundStyle(.primary)
            } icon: {
                Image(systemName: icon).foregroundStyle(LocusTheme.accent)
            }
        }
    }

    private func pick(_ place: PlaceRef) {
        searchFocused = false
        withAnimation(.snappy) {
            picked = place
            position = .region(MKCoordinateRegion(center: place.point.coordinate, latitudinalMeters: 1500, longitudinalMeters: 1500))
        }
    }

    private func select(_ completion: MKLocalSearchCompletion) {
        Task {
            let request = MKLocalSearch.Request(completion: completion)
            guard let response = try? await MKLocalSearch(request: request).start(),
                  let item = response.mapItems.first else { return }
            let coord = item.placemark.coordinate
            pick(PlaceRef(name: item.name ?? completion.title, point: GeoPoint(coord)))
            query = ""
        }
    }
}
