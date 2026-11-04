import CoreLocation
import SwiftUI

/// "Drive to …" — pick how to drive, see the ETA, start.
///
/// Uses the Scheduled Runs engine with a one-off run, so a drive gets the
/// same live dashboard, pause, speed change and background behaviour.
struct DriveOptionsSheet: View {
    let destination: MapPlace
    /// Real GPS start when not spoofing; nil = start from the simulated spot.
    let origin: CLLocationCoordinate2D?
    let onStarted: () -> Void

    @EnvironmentObject private var runs: ScheduledRunsController
    @EnvironmentObject private var session: SpoofSession
    @Environment(\.dismiss) private var dismiss

    @State private var run: ScheduledRun?
    @State private var preview: RunPreview?
    @State private var isCalculating = true

    private var canStart: Bool { session.isSpoofing || origin != nil }

    var body: some View {
        NavigationStack {
            Form {
                summarySection

                Section {
                    speedPicker
                    if runs.drivePrefs.speed != .followLimit {
                        speedValue
                    }
                    Toggle(isOn: $runs.drivePrefs.realism.varySpeed) {
                        Label("Vary speed naturally", systemImage: "waveform.path")
                    }
                } header: {
                    Text("Speed")
                } footer: {
                    Text(speedFooter)
                }

                Section {
                    Toggle(isOn: $runs.drivePrefs.realism.redLights) {
                        Label("Stop at red lights", systemImage: "light.beacon.max.fill")
                    }
                    if runs.drivePrefs.realism.redLights {
                        Picker(selection: $runs.drivePrefs.realism.maxRedLightWait) {
                            ForEach(DriveRealism.redLightChoices, id: \.self) { s in
                                Text(RunFormat.duration(s)).tag(s)
                            }
                        } label: {
                            Label("Longest wait", systemImage: "timer")
                        }
                    }
                    Toggle(isOn: $runs.drivePrefs.realism.stopSigns) {
                        Label("Stop at stop signs", systemImage: "octagon.fill")
                    }
                } header: {
                    Text("Traffic")
                } footer: {
                    Text("Locus doesn't know where real lights and signs are, so it adds stops at turns and intersections along the way. Red lights last a random time up to your limit.")
                }
            }
            .navigationTitle("Drive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                startButton
            }
        }
        .onAppear {
            if run == nil {
                run = runs.makeDrive(to: destination.placeRef, origin: origin.map { PlaceRef(name: "My Location", point: GeoPoint($0)) })
            }
        }
        .onChange(of: runs.drivePrefs) { _, prefs in
            guard var r = run else { return }
            runs.apply(prefs, to: &r)
            run = r
        }
        .task(id: run) {
            guard let run else { return }
            isCalculating = true
            // Debounce slider drags.
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let result = await runs.preview(run)
            guard !Task.isCancelled else { return }
            preview = result
            isCalculating = false
        }
    }

    // MARK: Summary

    private var summarySection: some View {
        Section {
            HStack(spacing: 12) {
                PlaceIcon(category: destination.category, kind: destination.kind, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(destination.name)
                        .font(.headline)
                        .lineLimit(2)
                    Text(fromLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            etaRow
        }
    }

    private var fromLine: String {
        if session.isSpoofing { return "From \(session.simulatedName ?? "your simulated location")" }
        return origin == nil ? "Waiting for your location…" : "From My Location"
    }

    @ViewBuilder private var etaRow: some View {
        if !canStart {
            Label("Locus can't find your location yet. Teleport somewhere first, then drive from there.", systemImage: "location.slash")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else if let error = preview?.error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(LocusTheme.statusWarn)
        } else if let preview, let duration = preview.estimatedDuration, let plan = preview.plan {
            let fmt = RunFormat(unit: runs.unit)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(RunFormat.eta(duration))
                    .font(.title.weight(.bold).monospacedDigit())
                    .contentTransition(.numericText())
                Text(fmt.distance(plan.totalDriveDistance))
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                if isCalculating { ProgressView().controlSize(.small) }
            }
            .animation(.snappy, value: duration)
            if let stops = stopSummary(plan) {
                Text(stops)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 10) {
                ProgressView()
                Text("Finding a route…").foregroundStyle(.secondary)
            }
            .font(.subheadline)
        }
    }

    private func stopSummary(_ plan: RunPlan) -> String? {
        var lights = 0, signs = 0, waiting = 0.0
        for seg in plan.segments {
            guard case .drive(let leg) = seg.kind else { continue }
            for stop in leg.profile.stops ?? [] {
                if stop.kind == .redLight { lights += 1 } else { signs += 1 }
                waiting += stop.dwell
            }
        }
        guard lights + signs > 0 else { return nil }
        var parts: [String] = []
        if lights > 0 { parts.append("\(lights) red light\(lights == 1 ? "" : "s")") }
        if signs > 0 { parts.append("\(signs) stop sign\(signs == 1 ? "" : "s")") }
        return "Includes \(parts.joined(separator: " and ")) · about \(RunFormat.duration(waiting)) stopped"
    }

    // MARK: Speed

    private enum SpeedChoice: String, CaseIterable, Identifiable {
        case limit = "At Limit", above = "Faster", below = "Slower", fixed = "Fixed"
        var id: String { rawValue }
    }

    private var speedChoice: Binding<SpeedChoice> {
        Binding {
            switch runs.drivePrefs.speed {
            case .followLimit: return .limit
            case .aboveLimit: return .above
            case .belowLimit: return .below
            case .constant: return .fixed
            }
        } set: { choice in
            let unit = runs.unit
            switch choice {
            case .limit: runs.drivePrefs.speed = .followLimit
            case .above: runs.drivePrefs.speed = .aboveLimit(unit.toMetersPerSecond(5))
            case .below: runs.drivePrefs.speed = .belowLimit(unit.toMetersPerSecond(5))
            case .fixed: runs.drivePrefs.speed = .constant(unit.toMetersPerSecond(unit == .mph ? 35 : 50))
            }
        }
    }

    private var speedPicker: some View {
        Picker("Speed", selection: speedChoice) {
            ForEach(SpeedChoice.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .listRowSeparator(.hidden)
    }

    private var speedValue: some View {
        let unit = runs.unit
        let isFixed: Bool = { if case .constant = runs.drivePrefs.speed { return true } else { return false } }()
        let range: ClosedRange<Double> = isFixed ? (unit == .mph ? 5...100 : 10...160) : (unit == .mph ? 1...20 : 2...30)
        let value = Binding<Double> {
            switch runs.drivePrefs.speed {
            case .followLimit: return 0
            case .constant(let v), .aboveLimit(let v), .belowLimit(let v): return unit.fromMetersPerSecond(v).rounded()
            }
        } set: { newValue in
            let mps = unit.toMetersPerSecond(newValue)
            switch runs.drivePrefs.speed {
            case .followLimit: break
            case .constant: runs.drivePrefs.speed = .constant(mps)
            case .aboveLimit: runs.drivePrefs.speed = .aboveLimit(mps)
            case .belowLimit: runs.drivePrefs.speed = .belowLimit(mps)
            }
        }
        return Stepper(value: value, in: range, step: isFixed ? 5 : 1) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(isFixed ? "Speed" : (speedChoice.wrappedValue == .above ? "Over the limit by" : "Under the limit by"))
                Spacer()
                Text("\(Int(value.wrappedValue)) \(unit.label)")
                    .font(.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(LocusTheme.accent)
                    .contentTransition(.numericText())
            }
        }
    }

    private var speedFooter: String {
        switch runs.drivePrefs.speed {
        case .followLimit:
            return "Drives at the usual speed for each road, slows for turns and eases to a stop at the end. Apple Maps doesn't share posted limits, so Locus uses the route's typical speed."
        case .constant:
            return "Holds this speed where the road allows, still slowing for turns."
        case .aboveLimit, .belowLimit:
            return "Relative to the usual speed for each road."
        }
    }

    // MARK: Start

    private var startButton: some View {
        Button {
            guard let run else { return }
            runs.startOneOff(run)
            onStarted()
            dismiss()
        } label: {
            Label(runs.isActive ? "Another run is in progress" : "Start Drive", systemImage: "car.fill")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 52)
        }
        .locusProminentButton()
        .buttonBorderShape(.capsule)
        .disabled(!canStart || run == nil || runs.isActive || preview?.error != nil)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(.bar)
    }
}
