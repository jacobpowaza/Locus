import SwiftUI

@main
struct LocusApp: App {
    @StateObject private var session = SpoofSession()
    @StateObject private var pairing = PairingStore()
    @StateObject private var scheduledRuns = ScheduledRunsController()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SetupGate.defaultsKey) private var setupComplete = false

    /// Map when setup finished, or when already paired outside this walkthrough.
    private var showMap: Bool {
        #if targetEnvironment(simulator)
        // No pairing file or VPN exists in the Simulator (or Appetize), so the
        // walkthrough can't be finished there. Pass -LocusShowSetup to see it.
        if !ProcessInfo.processInfo.arguments.contains("-LocusShowSetup") { return true }
        #endif
        return setupComplete || (pairing.hasPairingFile && !SetupGate.isInProgress)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if showMap {
                    RootView()
                } else {
                    SetupFlowView(initialStep: SetupGate.initialStep(hasPairingFile: pairing.hasPairingFile)) {
                        SetupGate.markComplete()
                        setupComplete = true
                    }
                }
            }
            .environmentObject(session)
            .environmentObject(pairing)
            .environmentObject(scheduledRuns)
            .task {
                scheduledRuns.attach(session: session, pairing: pairing)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { scheduledRuns.sceneBecameActive() }
            }
            .preferredColorScheme(.dark)
            .onOpenURL { url in
                handleIncoming(url)
            }
            .onAppear {
                if !setupComplete, pairing.hasPairingFile, !SetupGate.isInProgress {
                    SetupGate.markComplete()
                    setupComplete = true
                }
            }
        }
    }

    private func handleIncoming(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        if ["plist", "mobiledevicepairing", "mobiledevicepair"].contains(ext) {
            try? pairing.importPairing(from: url)
        } else if ext == "gpx" {
            NotificationCenter.default.post(name: .locusImportGPX, object: url)
        } else if url.scheme == "locus", url.host == "runs" {
            // locus://runs opens the Scheduled Runs dashboard.
            NotificationCenter.default.post(name: .locusOpenScheduledRuns, object: nil)
        }
    }
}

extension Notification.Name {
    static let locusImportGPX = Notification.Name("locusImportGPX")
    static let locusOpenScheduledRuns = Notification.Name("locusOpenScheduledRuns")
    static let locusOpenActiveRun = Notification.Name("locusOpenActiveRun")
}
