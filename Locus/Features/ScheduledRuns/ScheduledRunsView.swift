import SwiftUI

/// Dashboard: active run, your runs, upcoming schedule, history.
struct ScheduledRunsView: View {
    @EnvironmentObject private var runs: ScheduledRunsController
    @EnvironmentObject private var session: SpoofSession
    @Environment(\.dismiss) private var dismiss

    @State private var editing: EditorTarget?
    @State private var showActive = false
    @State private var showHistory = false
    @State private var showHowItWorks = false
    @State private var pendingDelete: ScheduledRun?

    struct EditorTarget: Identifiable {
        let id = UUID()
        var run: ScheduledRun
        var isNew: Bool
    }

    private var upcoming: [(run: ScheduledRun, date: Date)] {
        runs.runs.compactMap { r in runs.nextOccurrence(of: r).map { (r, $0) } }
            .sorted { $0.date < $1.date }
    }

    var body: some View {
        NavigationStack {
            List {
                if runs.snapshot != nil, let name = runs.activeRunName {
                    Section {
                        ActiveRunCard(name: name) { showActive = true }
                    }
                } else if let starting = runs.startingRunID, let r = runs.run(id: starting) {
                    Section { startingRow(r) }
                }

                if let done = runs.lastFinished {
                    Section { finishedRow(done) }
                }

                if runs.runs.isEmpty {
                    Section { emptyState }
                } else {
                    Section("My Runs") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                            ForEach(runs.runs) { run in
                                RunTile(
                                    run: run,
                                    next: runs.nextOccurrence(of: run),
                                    isRunning: runs.isActive && runs.activeRunID == run.id,
                                    isStarting: runs.startingRunID == run.id,
                                    onRun: { runs.start(run.id) },
                                    onEdit: { editing = EditorTarget(run: run, isNew: false) }
                                )
                                .contextMenu { tileMenu(run) }
                            }
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }
                }

                if !upcoming.isEmpty {
                    Section("Upcoming") {
                        ForEach(Array(upcoming.prefix(6).enumerated()), id: \.offset) { _, item in
                            HStack(spacing: 12) {
                                Circle().fill(RunsStyle.tint(item.run.tint)).frame(width: 10, height: 10)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.run.name).font(.subheadline.weight(.semibold))
                                    Text(RunFormat.dayAndTime(item.date, timeZone: item.run.timeZone))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(item.date, style: .relative)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if let last = runs.history.first {
                    Section("Recent") {
                        Button { showHistory = true } label: {
                            HStack {
                                HistoryRow(record: last, unit: runs.unit)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }

                Section {
                    Button { showHowItWorks = true } label: {
                        Label("How scheduling works on iPhone", systemImage: "info.circle")
                    }
                    .tint(LocusTheme.accent)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Scheduled Runs")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { showHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }
                        .accessibilityLabel("Run history")
                    Menu {
                        Button { editing = EditorTarget(run: blankRun(), isNew: true) } label: {
                            Label("New Run", systemImage: "plus")
                        }
                        Button { editing = EditorTarget(run: commuteExample(), isNew: true) } label: {
                            Label("Commute Example", systemImage: "car")
                        }
                    } label: {
                        Image(systemName: "plus")
                    } primaryAction: {
                        editing = EditorTarget(run: blankRun(), isNew: true)
                    }
                    .accessibilityLabel("New run")
                }
            }
            .sheet(item: $editing) { target in
                RunEditorView(original: target.run, isNew: target.isNew)
            }
            .fullScreenCover(isPresented: $showActive) {
                ActiveRunView()
            }
            .sheet(isPresented: $showHistory) {
                RunHistoryView()
            }
            .sheet(isPresented: $showHowItWorks) {
                HowSchedulingWorksView()
                    .presentationDetents([.medium, .large])
            }
            .confirmationDialog(
                "Delete \"\(pendingDelete?.name ?? "")\"?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete Run", role: .destructive) {
                    if let r = pendingDelete { runs.delete(r.id) }
                    pendingDelete = nil
                }
            }
            .alert("Scheduled Runs", isPresented: Binding(get: { runs.errorMessage != nil }, set: { if !$0 { runs.errorMessage = nil } })) {
                Button("OK", role: .cancel) { runs.errorMessage = nil }
            } message: {
                Text(runs.errorMessage ?? "")
            }
        }
    }

    @ViewBuilder
    private func tileMenu(_ run: ScheduledRun) -> some View {
        Button { runs.start(run.id) } label: { Label("Run Now", systemImage: "play.fill") }
            .disabled(runs.isActive)
        Button { editing = EditorTarget(run: run, isNew: false) } label: { Label("Edit", systemImage: "pencil") }
        Button { runs.duplicate(run.id) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
        if run.schedule.isAutomatic {
            Button { runs.setEnabled(!run.isEnabled, id: run.id) } label: {
                Label(run.isEnabled ? "Turn Off Schedule" : "Turn On Schedule",
                      systemImage: run.isEnabled ? "bell.slash" : "bell")
            }
        }
        Button(role: .destructive) { pendingDelete = run } label: { Label("Delete", systemImage: "trash") }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(LocusTheme.accent)
            Text("Automate your location")
                .font(.title3.weight(.bold))
            Text("Chain steps like Set Location, Wait and Drive To, then run them now or on a schedule.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button {
                    editing = EditorTarget(run: blankRun(), isNew: true)
                } label: {
                    Label("New Run", systemImage: "plus")
                }
                .buttonStyle(LocusPillButtonStyle(role: .primary))
                Button {
                    editing = EditorTarget(run: commuteExample(), isNew: true)
                } label: {
                    Label("Try the commute", systemImage: "car")
                }
                .buttonStyle(LocusPillButtonStyle(role: .secondary))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private func startingRow(_ r: ScheduledRun) -> some View {
        HStack(spacing: 12) {
            ProgressView()
            VStack(alignment: .leading) {
                Text("Starting \(r.name)…").font(.subheadline.weight(.semibold))
                Text("Getting routes from Apple Maps").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func finishedRow(_ record: RunRecord) -> some View {
        HStack(spacing: 12) {
            Image(systemName: record.outcome == .completed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(record.outcome == .completed ? LocusTheme.statusGood : LocusTheme.statusWarn)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(record.runName) · \(record.outcome.label)").font(.subheadline.weight(.semibold))
                Text(record.message ?? "Simulated \(RunFormat(unit: runs.unit).distance(record.distance)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button {
                runs.dismissLastFinished()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
        }
    }

    private func blankRun() -> ScheduledRun {
        ScheduledRun(name: "New Run", tint: runs.runs.count % RunsStyle.tints.count)
    }

    private func commuteExample() -> ScheduledRun {
        let here = session.simulated ?? session.pin ?? session.realCoordinate
        let favs = session.favorites
        let homePlace = favs.first.map(PlaceRef.init)
            ?? here.map { PlaceRef(name: "Home", point: GeoPoint($0)) }
            ?? PlaceRef(name: "Home", point: GeoPoint(latitude: 37.3349, longitude: -122.0090))
        let workPlace = favs.dropFirst().first.map(PlaceRef.init)
            ?? PlaceRef(name: "Work", point: GeoPoint(latitude: homePlace.point.latitude + 0.03, longitude: homePlace.point.longitude + 0.02))
        var r = ScheduledRun.commuteTemplate(home: homePlace, work: workPlace)
        r.tint = 1
        return r
    }
}

/// One run in the grid.
struct RunTile: View {
    let run: ScheduledRun
    let next: Date?
    let isRunning: Bool
    let isStarting: Bool
    let onRun: () -> Void
    let onEdit: () -> Void

    var body: some View {
        let tint = RunsStyle.tint(run.tint)
        Button(action: onEdit) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    Image(systemName: run.schedule.isAutomatic ? "calendar.badge.clock" : "point.topleft.down.to.point.bottomright.curvepath")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Button(action: onRun) {
                        Group {
                            if isStarting {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: isRunning ? "waveform" : "play.fill")
                                    .symbolEffect(.variableColor.iterative, isActive: isRunning)
                            }
                        }
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(tint)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(.white))
                    }
                    .buttonStyle(.plain)
                    .disabled(isRunning || isStarting)
                    .accessibilityLabel(isRunning ? "Running" : "Run \(run.name) now")
                }
                Spacer(minLength: 4)
                Text(run.name)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(subtitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: 128, alignment: .leading)
            .padding(14)
            .locusGlass(.interactive, tint: tint.opacity(isOff ? 0.35 : 0.85),
                        in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var isOff: Bool { run.schedule.isAutomatic && !run.isEnabled }

    private var subtitle: String {
        let steps = "\(run.actions.count) step\(run.actions.count == 1 ? "" : "s")"
        if run.schedule.isAutomatic && !run.isEnabled { return "\(steps) · Schedule off" }
        if let next { return "\(steps) · Next \(RunFormat.dayAndTime(next, timeZone: run.timeZone))" }
        return "\(steps) · \(RunFormat.schedule(run.schedule))"
    }
}

/// Banner for the run in progress.
struct ActiveRunCard: View {
    @EnvironmentObject private var runs: ScheduledRunsController
    let name: String
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let s = runs.liveSnapshot()
                let fmt = RunFormat(unit: runs.unit)
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label(s?.status == .paused ? "Paused" : "Running", systemImage: s?.status == .paused ? "pause.circle.fill" : "dot.radiowaves.left.and.right")
                            .font(.caption.weight(.bold))
                            .textCase(.uppercase)
                            .foregroundStyle(s?.status == .paused ? LocusTheme.statusWarn : LocusTheme.statusGood)
                        Spacer()
                        SimulatedBadge()
                    }
                    Text(name).font(.headline)
                    if let seg = s?.segment {
                        Text(seg.summary).font(.subheadline).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 18) {
                        stat(fmt.speed(s?.speed ?? 0), "speed")
                        stat(fmt.distance(s?.distanceRemaining ?? 0), "left")
                        if let end = s?.runEnd { stat(RunFormat.time(end), "ends") }
                    }
                    if let s, s.segmentCount > 0 {
                        ProgressView(value: Double(min(s.segmentIndex, s.segmentCount)), total: Double(s.segmentCount))
                            .tint(LocusTheme.accent)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .buttonStyle(.plain)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.subheadline.weight(.bold).monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct HowSchedulingWorksView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(ScheduledRunsController.platformNotes, id: \.self) { note in
                        Text(note).font(.subheadline)
                    }
                } footer: {
                    Text("For the most reliable timing, keep Locus open (or recently used) and LocalDevVPN connected before a scheduled start.")
                }
            }
            .navigationTitle("How scheduling works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
