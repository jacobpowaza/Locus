import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var pairing: PairingStore
    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var runs: ScheduledRunsController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var vpnConnected = LocalDevVPN.isConnected
    @State private var vpnInstalled = LocalDevVPN.isInstalled
    @State private var showNameEasterEgg = false

    private var isReady: Bool { pairing.hasPairingFile && vpnConnected }

    private var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(isReady ? LocusTheme.statusGood : LocusTheme.statusWarn)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(isReady ? "Ready to Go" : "Almost Ready")
                                .font(.headline)
                            Text(readinessText)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    NavigationLink {
                        PairingSettingsView()
                    } label: {
                        row("iPhone Pairing", symbol: "iphone.gen3", color: .blue,
                            value: pairing.hasPairingFile ? "Set Up" : "Not Set Up",
                            warn: !pairing.hasPairingFile)
                    }
                    Button {
                        if vpnInstalled { LocalDevVPN.openInstalled() } else { LocalDevVPN.openAppStore() }
                    } label: {
                        row("LocalDevVPN", symbol: "lock.shield.fill", color: .green,
                            value: vpnConnected ? "Connected" : (vpnInstalled ? "Off — Open" : "Get the App"),
                            warn: !vpnConnected)
                    }
                    .foregroundStyle(.primary)
                } header: {
                    Text("Connection")
                } footer: {
                    Text("Locus needs both to change your location. Turn on LocalDevVPN while on Wi‑Fi before you teleport.")
                }

                Section("Preferences") {
                    Picker(selection: $runs.unit) {
                        ForEach(SpeedUnit.allCases) { Text($0 == .mph ? "Miles (mph)" : "Kilometers (km/h)").tag($0) }
                    } label: {
                        row("Units", symbol: "ruler.fill", color: .orange)
                    }
                    Picker(selection: $session.mapStyleIndex) {
                        Text("Explore").tag(0)
                        Text("Hybrid").tag(1)
                        Text("Satellite").tag(2)
                    } label: {
                        row("Map Style", symbol: "map.fill", color: .teal)
                    }
                }

                Section {
                    NavigationLink {
                        AdvancedSettingsView()
                    } label: {
                        row("Advanced", symbol: "wrench.and.screwdriver.fill", color: .gray)
                    }
                }

                Section {
                    LabeledContent("Version", value: appVersion)
                    Label("Everything stays on this iPhone. No accounts, no tracking.", systemImage: "hand.raised.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("About")
                } footer: {
                    Button {
                        showNameEasterEgg = true
                    } label: {
                        Text("locus, n. — a place. From the Latin for where you are.")
                            .font(.footnote.italic())
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 16)
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .fullScreenCover(isPresented: $showNameEasterEgg) {
                LocusEasterEggView()
            }
            .onAppear(perform: refresh)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { refresh() }
            }
        }
    }

    private var readinessText: String {
        if !pairing.hasPairingFile { return "Set up iPhone Pairing to start." }
        if !vpnConnected { return "Turn on LocalDevVPN to change your location." }
        return "Search for a place and tap Teleport."
    }

    private func refresh() {
        vpnConnected = LocalDevVPN.isConnected
        vpnInstalled = LocalDevVPN.isInstalled
    }

    private func row(_ title: String, symbol: String, color: Color, value: String? = nil, warn: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(color.gradient))
            Text(title)
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .foregroundStyle(warn ? LocusTheme.statusWarn : .secondary)
            }
        }
    }
}

/// Pairing file setup, with the long explanations kept off the main page.
struct PairingSettingsView: View {
    @EnvironmentObject private var pairing: PairingStore
    @EnvironmentObject private var session: SpoofSession

    @State private var showImporter = false
    @State private var showPairOnDevice = false
    @State private var confirmRemove = false
    @State private var message: String?

    private var supportsOnDevicePairing: Bool {
        if #available(iOS 27.0, *) { return true }
        return false
    }

    var body: some View {
        List {
            Section {
                Label {
                    Text(pairing.hasPairingFile ? "This iPhone is paired" : "Not paired yet")
                } icon: {
                    Image(systemName: pairing.hasPairingFile ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(pairing.hasPairingFile ? LocusTheme.statusGood : LocusTheme.statusWarn)
                }
            }

            Section {
                if supportsOnDevicePairing {
                    Button {
                        showPairOnDevice = true
                    } label: {
                        Label("Pair on This iPhone", systemImage: "iphone.gen3.radiowaves.left.and.right")
                    }
                }
                Button {
                    showImporter = true
                } label: {
                    Label("Import Pairing File…", systemImage: "doc.badge.plus")
                }
                Button {
                    do {
                        try pairing.importPairingFromClipboard()
                        message = "Pairing file added."
                    } catch {
                        message = error.localizedDescription
                    }
                } label: {
                    Label("Paste Pairing File", systemImage: "doc.on.clipboard")
                }
            } footer: {
                Text(supportsOnDevicePairing
                     ? "Tap Pair on This iPhone, then confirm the 6-digit code in Settings › Privacy & Security › Developer Mode › Pair with Host. No computer needed."
                     : "Make an RPPairing file once with idevice_pair on a computer, then import it here. (A SideStore .mobiledevicepairing file won't work.)")
            }

            Section {
                Text("If Import does nothing (common in LiveContainer): turn on Fix File Picker for Locus, share the file into LiveContainer › Locus, or copy the file's contents and use Paste.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Trouble Importing?")
            }

            if pairing.hasPairingFile {
                Section {
                    Button("Remove Pairing File", role: .destructive) { confirmRemove = true }
                }
            }
        }
        .navigationTitle("iPhone Pairing")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showImporter) {
            PairingDocumentPicker(
                onPick: { url in
                    showImporter = false
                    do {
                        try pairing.importPairing(from: url)
                        message = "Pairing file added."
                    } catch {
                        message = error.localizedDescription
                    }
                },
                onCancel: { showImporter = false }
            )
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showPairOnDevice) {
            PairOnDeviceView()
                .environmentObject(pairing)
        }
        .confirmationDialog("Remove the pairing file?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { try? pairing.removePairing() }
        } message: {
            Text("Locus won't be able to change your location until you pair again.")
        }
        .alert("iPhone Pairing", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
    }
}

/// Tunnel address and engine details. Most people never need this.
struct AdvancedSettingsView: View {
    @State private var tunnelIP = TunnelConfig.targetIP
    @State private var showHowItWorks = false

    var body: some View {
        List {
            Section {
                LabeledContent("Tunnel IP") {
                    TextField("10.7.0.1", text: $tunnelIP)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { TunnelConfig.setTargetIP(tunnelIP) }
                }
                if tunnelIP != "10.7.0.1" {
                    Button("Reset to 10.7.0.1") {
                        tunnelIP = "10.7.0.1"
                        TunnelConfig.setTargetIP(tunnelIP)
                    }
                }
            } footer: {
                Text("Only change this if you set LocalDevVPN to a different address.")
            }

            Section {
                Button("How Scheduled Runs Work in the Background") { showHowItWorks = true }
            }

            Section("About the Engine") {
                LabeledContent("Method", value: "Developer location simulation")
                Text("Locus is free and open source (MIT). Location changes go through Apple's developer location service using the MIT-licensed idevice library.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { TunnelConfig.setTargetIP(tunnelIP) }
        .sheet(isPresented: $showHowItWorks) {
            HowSchedulingWorksView()
                .presentationDetents([.medium, .large])
        }
    }
}

/// All favorites and recents. Picking one opens its place card on the map.
struct PlacesView: View {
    @EnvironmentObject private var session: SpoofSession
    @Environment(\.dismiss) private var dismiss
    let onPick: (MapPlace) -> Void

    @State private var placeToRename: SavedPlace?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Favorites") {
                    if session.favorites.isEmpty {
                        Text("Tap the star on any place to save it here.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(session.favorites) { place in
                        row(place, kind: .favorite)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    session.removeFavorite(place)
                                } label: {
                                    Label("Delete", systemImage: "trash.fill")
                                }
                                Button {
                                    placeToRename = place
                                    renameText = place.name
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                .tint(.gray)
                            }
                    }
                }

                if !session.recents.isEmpty {
                    Section("Recents") {
                        ForEach(session.recents) { place in
                            row(place, kind: .recent)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        session.removeRecent(place)
                                    } label: {
                                        Label("Delete", systemImage: "trash.fill")
                                    }
                                }
                        }
                    }
                }
            }
            .navigationTitle("Saved Places")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Rename Favorite", isPresented: Binding(
                get: { placeToRename != nil },
                set: { if !$0 { placeToRename = nil } }
            )) {
                TextField("Name", text: $renameText)
                Button("Cancel", role: .cancel) { placeToRename = nil }
                Button("Save") {
                    if let place = placeToRename { session.renameFavorite(place, to: renameText) }
                    placeToRename = nil
                }
            } message: {
                Text("Choose a name you'll recognize later.")
            }
        }
    }

    private func row(_ place: SavedPlace, kind: MapPlace.Kind) -> some View {
        Button {
            onPick(MapPlace(saved: place, kind: kind))
        } label: {
            HStack(spacing: 12) {
                if kind == .favorite {
                    Image(systemName: HomePanel.favoriteSymbol(place.name))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color(red: 1.0, green: 0.75, blue: 0.2).gradient))
                } else {
                    PlaceIcon(kind: kind, size: 36)
                }
                Text(place.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
        }
    }
}
