import SwiftUI
import UIKit
import UserNotifications

@main
struct LocusApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: LocusAppDelegate
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
            .environmentObject(appDelegate)
            .environmentObject(session)
            .environmentObject(pairing)
            .environmentObject(scheduledRuns)
            .task {
                scheduledRuns.attach(session: session, pairing: pairing)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { scheduledRuns.sceneBecameActive() }
            }
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
            do { try pairing.importPairing(from: url) }
            catch { session.lastError = error.localizedDescription }
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


@MainActor
final class LocusAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate, ObservableObject {
    @Published var reminderRunID: UUID?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                             withCompletionHandler completionHandler: @escaping () -> Void) {
        if let value = response.notification.request.content.userInfo["runID"] as? String,
           let id = UUID(uuidString: value) {
            Task { @MainActor in self.reminderRunID = id }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                             withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
