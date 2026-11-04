import SwiftUI

/// Live dashboard for the run in progress.
struct ActiveRunView: View {
    @EnvironmentObject private var runs: ScheduledRunsController
    @Environment(\.dismiss) private var dismiss
    @State private var confirmCancel = false
    @State private var showSpeed = false
    @State private var speedDraft: SpeedPolicy = .followLimit

    var body: some View {
        NavigationStack {
            Group {
                if let plan = runs.activePlan {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        if let s = runs.liveSnapshot() {
                            content(plan: plan, s: s, now: context.date)
                        } else {
                            finished
                        }
                    }
                } else {
                    finished
                }
            }
            .navigationTitle(runs.activeRunName ?? "Run")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("End this run?", isPresented: $confirmCancel, titleVisibility: .visible) {
                Button("End & Stay Here") { runs.cancel(stopSpoofing: false) }
                Button("End & Stop Spoofing", role: .destructive) { runs.cancel(stopSpoofing: true) }
            } message: {
                Text("Staying keeps the simulated location where it is now.")
            }
            .sheet(isPresented: $showSpeed) {
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
                .presentationDetents([.medium])
            }
        }
    }

    private var finished: some View {
        ContentUnavailableView {
            Label(runs.lastFinished?.outcome.label ?? "No active run", systemImage: "flag.checkered")
        } description: {
            if let r = runs.lastFinished {
                Text(r.message ?? "\(r.runName) finished. Locus stays at the last simulated location until you stop spoofing.")
            }
        }
    }

    @ViewBuilder
    private func content(plan: RunPlan, s: ExecutionSnapshot, now: Date) -> some View {
        let fmt = RunFormat(unit: runs.unit)
        let tz = TimeZone(identifier: plan.timeZoneID) ?? .current
        ScrollView {
            VStack(spacing: 16) {
                ZStack(alignment: .topLeading) {
                    RoutePreviewMap(plan: plan, current: s.position, heading: s.speed > 0.5 ? s.heading : nil)
                        .frame(height: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    SimulatedBadge().padding(10)
                }

                statusBanner(s)

                // Primary readouts.
                HStack(spacing: 12) {
                    bigStat(fmt.speedNumber(s.speed), unit: runs.unit.label, label: "Simulated speed")
                    if let ref = s.referenceSpeed {
                        bigStat(fmt.speedNumber(ref), unit: runs.unit.label,
                                label: (s.referenceSource?.isFallback ?? true) ? "Limit (est.)" : "Speed limit")
                    }
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    stat(fmt.distance(s.legDistanceRemaining ?? 0), "Leg remaining")
                    stat(s.legArrival.map { RunFormat.time($0, timeZone: tz) } ?? "—", "Leg ETA")
                    stat(fmt.distance(s.distanceRemaining), "Run remaining")
                    stat(RunFormat.time(s.runEnd, timeZone: tz), "Run ETA")
                    stat(RunFormat.duration(s.activeElapsed), "Elapsed")
                    stat(fmt.distance(s.distanceDriven), "Driven")
                }

                if let ends = s.holdEnds, case .waitUntil? = s.segment?.kind {
                    Label("Holding until \(RunFormat.time(ends, timeZone: tz))", systemImage: "clock")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .runCard()
                } else if let ends = s.holdEnds {
                    Label {
                        Text("Waiting · ") + Text(ends, style: .timer) + Text(" left")
                    } icon: { Image(systemName: "hourglass") }
                        .font(.subheadline.monospacedDigit())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .runCard()
                }

                controls(s)

                steps(plan: plan, s: s, tz: tz)
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    @ViewBuilder
    private func statusBanner(_ s: ExecutionSnapshot) -> some View {
        if s.status == .paused {
            Label(s.pauseReason ?? "Paused", systemImage: "pause.circle.fill")
                .font(.subheadline)
                .foregroundStyle(LocusTheme.statusWarn)
                .frame(maxWidth: .infinity, alignment: .leading)
                .runCard(tint: LocusTheme.statusWarn)
        } else if s.connectionProblem {
            Label("Can't reach the spoofing tunnel — retrying. Check LocalDevVPN.", systemImage: "wifi.exclamationmark")
                .font(.subheadline)
                .foregroundStyle(LocusTheme.statusBad)
                .frame(maxWidth: .infinity, alignment: .leading)
                .runCard(tint: LocusTheme.statusBad)
        } else if let seg = s.segment {
            HStack {
                Text("Step \(s.segmentIndex + 1) of \(s.segmentCount)")
                    .font(.caption.weight(.bold)).foregroundStyle(.secondary)
                Text(seg.summary).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
            }
        }
    }

    private func controls(_ s: ExecutionSnapshot) -> some View {
        HStack(spacing: 10) {
            if s.status == .paused {
                controlButton("Resume", "play.fill", LocusTheme.accent, prominent: true) { runs.resume() }
            } else {
                controlButton("Pause", "pause.fill", LocusTheme.accent, prominent: true) { runs.pause() }
            }
            controlButton("Skip", "forward.end.fill", .secondary) { runs.skip() }
            controlButton("Speed", "gauge.with.dots.needle.67percent", RunsStyle.color(.setSpeed)) {
                speedDraft = s.speedPolicy
                showSpeed = true
            }
            controlButton("End", "stop.fill", LocusTheme.danger) { confirmCancel = true }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: s.status)
    }

    private func controlButton(_ title: String, _ icon: String, _ color: Color, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.headline)
                Text(title).font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .foregroundStyle(prominent ? .black : color)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(prominent ? color : color.opacity(0.14))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func steps(plan: RunPlan, s: ExecutionSnapshot, tz: TimeZone) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Steps").font(.headline)
            VStack(spacing: 10) {
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
            .runCard()
        }
    }

    private func bigStat(_ value: String, unit: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                Text(unit).font(.subheadline).foregroundStyle(.secondary)
            }
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .runCard()
        .accessibilityElement(children: .combine)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.headline.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .runCard(padding: 12)
        .accessibilityElement(children: .combine)
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
