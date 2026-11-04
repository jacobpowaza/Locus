import SwiftUI

struct RootView: View {
    @EnvironmentObject private var session: SpoofSession
    @EnvironmentObject private var runs: ScheduledRunsController

    var body: some View {
        MapHomeView()
            .alert("Locus", isPresented: Binding(
                get: { session.lastError != nil },
                set: { if !$0 { session.lastError = nil } }
            )) {
                Button("OK", role: .cancel) { session.lastError = nil }
            } message: {
                Text(session.lastError ?? "")
            }
            .alert("Couldn't Start", isPresented: Binding(
                get: { runs.errorMessage != nil && !runs.isPresentingRunsUI },
                set: { if !$0 { runs.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { runs.errorMessage = nil }
            } message: {
                Text(runs.errorMessage ?? "")
            }
    }
}
