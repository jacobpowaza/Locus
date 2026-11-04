import SwiftUI

/// Live run, laid out like the main map screen: the map fills the screen,
/// with glass chrome on top and a glass control tray at the bottom.
struct ActiveRunView: View {
    @EnvironmentObject private var runs: ScheduledRunsController
    @Environment(\.dismiss) private var dismiss
    @State private var confirmCancel = false
    @State private var showSpeed = false
    @State private var showSteps = false
    @State private var speedDraft: SpeedPolicy = .followLimit

    var body: some View {
        Group {
            if let plan = runs.activePlan {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    if let s = runs.liveSnapshot() {
                        content(plan: plan, s: s)
                    } else {
                        finished
                    }
                }
            } else {
                finished
            }
        }
        .confirmationDialog("End this run?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("End & Stay Here") { runs.cancel(stopSpoofing: false) }
            Button("End & Stop Spoofing", role: .destructive) { runs.cancel(stopSpoofing: true) }
        } message: {
            Text("Staying keeps the simulated location where it is now.")
        }
        .sheet(isPresented: $showSpeed) { speedSheet }
        .sheet(isPresented: $showSteps) { stepsSheet }
    }

    // MARK: Finished / empty

    private var finished: some View {
        NavigationStack {
            ContentUnavailableView {
                Label(runs.lastFinished?.outcome.label ?? "No active run", systemImage: "flag.checkered")
            } description: {
                if let r = runs.lastFinished {
                    Text(r.message ?? "\(r.runName) finished. Locus stays at the last simulated location until you stop spoofing.")
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    // MARK: Live layout

    private func content(plan: RunPlan, s: ExecutionSnapshot) -> some View {
        let fmt = RunFormat(unit: runs.unit)
        let tz = TimeZone(identifier: plan.timeZoneID) ?? .current
        return ZStack {
            RoutePreviewMap(plan: plan, current: s.position, heading: s.speed > 0.5 ? s.heading : nil)
                .ignoresSafeArea()

            VStack(spacing: 10) {
                topChrome(s, fmt: fmt)
                Spacer(minLength: 0)
                HStack {
                    speedCluster(s, fmt: fmt)
                    Spacer(minLength: 0)
                }
                tray(s, fmt: fmt, tz: tz)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .safeAreaPadding(.top, 8)
        }
        .animation(.snappy, value: s.status)
        .animation(.snappy, value: s.connectionProblem)
    }

    private func topChrome(_ s: ExecutionSnapshot, fmt: RunFormat) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down")
                        .font(.body.weight(.semibold))
                        .frame(width: 48, height: 48)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .locusGlass(.interactive, in: Circle())
                .foregroundStyle(.primary)
                .accessibilityLabel("Close run dashboard")

                HStack(spacing: 10) {
                    Circle()
                        .fill(statusColor(s))
                        .frame(width: 8, height: 8)
                        .shadow(color: statusColor(s).opacity(0.7), radius: 4)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(runs.activeRunName ?? "Run")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(stepLine(s))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    if let leg = s.legDistanceRemaining, leg > 1 {
                        Text(fmt.distance(leg))
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .contentTransition(.numericText())
                    }
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 48)
                .runGlassPanel(cornerRadius: 18)
                .accessibilityElement(children: .combine)
            }

            if let notice = notice(s) {
                Label {
                    Text(notice.text).foregroundStyle(.primary)
                } icon: {
                    Image(systemName: notice.icon).foregroundStyle(notice.color)
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .runGlassPanel(cornerRadius: 16, tint: notice.color.opacity(0.22))
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    /// Floating speed readout, like a navigation app's speedometer.
    private func speedCluster(_ s: ExecutionSnapshot, fmt: RunFormat) -> some View {
        let estimated = s.referenceSource?.isFallback ?? true
        return VStack(alignment: .leading, spacing: 6) {
            SimulatedBadge()
            HStack(alignment: .center, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(fmt.speedNumber(s.speed))
                        .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                    Text(runs.unit.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                if let ref = s.referenceSpeed {
                    Divider().frame(height: 30)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(fmt.speedNumber(ref))
                            .font(.headline.monospacedDigit())
                        Text(estimated ? "Limit (est.)" : "Limit")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .runGlassPanel(cornerRadius: 20)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(speedAccessibility(s, fmt: fmt, estimated: estimated))
    }

    private func tray(_ s: ExecutionSnapshot, fmt: RunFormat, tz: TimeZone) -> some View {
        let trayShape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        return VStack(spacing: 12) {
            // Arrival summary; tap for the step list.
            Button { showSteps = true } label: {
                HStack(spacing: 0) {
                    trayStat(RunFormat.time(s.runEnd, timeZone: tz), "arrival")
                    trayStat(fmt.distance(s.distanceRemaining), "left")
                    trayStat(RunFormat.duration(s.activeElapsed), "elapsed")
                    Image(systemName: "chevron.up")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows every step")

            if s.segmentCount > 0 {
                ProgressView(value: Double(min(s.segmentIndex, s.segmentCount)), total: Double(s.segmentCount))
                    .tint(LocusTheme.accent)
                    .accessibilityLabel("Step \(min(s.segmentIndex + 1, s.segmentCount)) of \(s.segmentCount)")
            }

            if let ends = s.holdEnds {
                holdLine(ends, s: s, tz: tz)
            }

            HStack(spacing: 10) {
                if s.status == .paused {
                    Button { runs.resume() } label: { Label("Resume", systemImage: "play.fill") }
                        .buttonStyle(LocusPillButtonStyle(role: .primary, expand: true))
                } else {
                    Button { runs.pause() } label: { Label("Pause", systemImage: "pause.fill") }
                        .buttonStyle(LocusPillButtonStyle(role: .primary, expand: true))
                }
                Button { runs.skip() } label: { Image(systemName: "forward.end.fill") }
                    .buttonStyle(LocusRoundButtonStyle())
                    .accessibilityLabel("Skip step")
                Button {
                    speedDraft = s.speedPolicy
                    showSpeed = true
                } label: { Image(systemName: "gauge.with.dots.needle.67percent") }
                    .buttonStyle(LocusRoundButtonStyle())
                    .accessibilityLabel("Change speed")
                Button { confirmCancel = true } label: { Text("End") }
                    .buttonStyle(LocusPillButtonStyle(role: .danger))
                    .accessibilityLabel("End run")
            }
            .sensoryFeedback(.impact(weight: .light), trigger: s.status)
        }
        .padding(14)
        .locusGlass(.regular, in: trayShape)
        .contentShape(trayShape)
    }

    private func trayStat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func holdLine(_ ends: Date, s: ExecutionSnapshot, tz: TimeZone) -> some View {
        Group {
            if case .waitUntil? = s.segment?.kind {
                Label("Holding until \(RunFormat.time(ends, timeZone: tz))", systemImage: "clock")
            } else {
                Label {
                    Text("Waiting · ") + Text(ends, style: .timer) + Text(" left")
                } icon: { Image(systemName: "hourglass") }
            }
        }
        .font(.subheadline.weight(.semibold).monospacedDigit())
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
    }

    // MARK: Sheets

    private var speedSheet: some View {
        NavigationStack {
            Form {
                SpeedPolicyEditor(policy: $speedDraft, unit: runs.unit, referenceSource: runs.snapshot?.referenceSource)
                Section {
                    Text("Applies to the current drive and later drives until the next Set Speed step. Drives with their own custom speed keep it.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Change Speed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showSpeed = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        runs.changeSpeed(speedDraft)
                        showSpeed = false
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var stepsSheet: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                if let plan = runs.activePlan, let s = runs.liveSnapshot() {
                    let tz = TimeZone(identifier: plan.timeZoneID) ?? .current
                    List {
                        ForEach(plan.segments.indices, id: \.self) { i in
                            let projIndex = i - s.segmentIndex
                            TimelineRow(
                                segment: plan.segments[i],
                                projected: projIndex >= 0 && projIndex < s.projected.count ? s.projected[projIndex] : nil,
                                timeZone: tz,
                                unit: runs.unit,
                                phase: i < s.segmentIndex ? .done : (i == s.segmentIndex ? .current : .upcoming)
                            )
                        }
                    }
                } else {
                    ContentUnavailableView("No active run", systemImage: "flag.checkered")
                }
            }
            .navigationTitle("Steps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { showSteps = false } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: Text

    private func statusColor(_ s: ExecutionSnapshot) -> Color {
        if s.status == .paused { return LocusTheme.statusWarn }
        if s.connectionProblem { return LocusTheme.statusBad }
        return LocusTheme.statusGood
    }

    private func stepLine(_ s: ExecutionSnapshot) -> String {
        guard let seg = s.segment else { return "" }
        return "Step \(s.segmentIndex + 1) of \(s.segmentCount) · \(seg.summary)"
    }

    private func notice(_ s: ExecutionSnapshot) -> (text: String, icon: String, color: Color)? {
        if s.status == .paused {
            return (s.pauseReason ?? "Paused", "pause.circle.fill", LocusTheme.statusWarn)
        }
        if s.connectionProblem {
            return ("Can't reach the spoofing tunnel — retrying. Check LocalDevVPN.", "wifi.exclamationmark", LocusTheme.statusBad)
        }
        return nil
    }

    private func speedAccessibility(_ s: ExecutionSnapshot, fmt: RunFormat, estimated: Bool) -> String {
        var text = "Simulated speed \(fmt.speed(s.speed))"
        if let ref = s.referenceSpeed {
            text += estimated ? ", estimated limit \(fmt.speed(ref))" : ", speed limit \(fmt.speed(ref))"
        }
        return text
    }
}

/// Compact banner over the main map while a run is active.
struct ActiveRunBanner: View {
    @EnvironmentObject private var runs: ScheduledRunsController
    let onTap: () -> Void

    var body: some View {
        if runs.isActive, let name = runs.activeRunName {
            Button(action: onTap) {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let s = runs.liveSnapshot()
                    let fmt = RunFormat(unit: runs.unit)
                    HStack(spacing: 10) {
                        Image(systemName: s?.status == .paused ? "pause.circle.fill" : "calendar.badge.clock")
                            .foregroundStyle(s?.status == .paused ? LocusTheme.statusWarn : LocusTheme.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(name).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(s?.segment?.summary ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        if let s, s.speed > 0.3 {
                            Text(fmt.speed(s.speed)).font(.caption.weight(.bold).monospacedDigit())
                        }
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .locusGlass(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityLabel("Scheduled run \(name) in progress. Open run dashboard.")
        }
    }
}
