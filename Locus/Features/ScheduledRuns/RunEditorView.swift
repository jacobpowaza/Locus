import SwiftUI

/// Create / edit a run: name, action blocks, schedule, speed, live preview.
struct RunEditorView: View {
    let original: ScheduledRun
    let isNew: Bool

    @EnvironmentObject private var runs: ScheduledRunsController
    @Environment(\.dismiss) private var dismiss

    @State private var draft: ScheduledRun
    @State private var preview: RunPreview?
    @State private var isPreviewing = false
    @State private var showAddAction = false
    @State private var editingAction: RunAction?
    @State private var showTimeline = false
    @State private var confirmDiscard = false
    @State private var editMode: EditMode = .inactive
    @FocusState private var nameFocused: Bool

    init(original: ScheduledRun, isNew: Bool) {
        self.original = original
        self.isNew = isNew
        _draft = State(initialValue: original)
    }

    private var hasChanges: Bool { isNew || draft != original }

    /// Instant validation plus route-aware issues from the last preview.
    private var issues: [RunIssue] {
        var seen = Set<String>()
        let all = RunValidator.validate(draft) + (preview?.issues ?? [])
        return all.filter { seen.insert($0.id).inserted }
    }

    private var runLevelIssues: [RunIssue] { issues.filter { $0.actionID == nil } }

    private func issuesFor(_ id: UUID) -> [RunIssue] {
        var list = issues.forAction(id)
        if let p = preview, p.errorActionID == id, let message = p.error {
            list.append(RunIssue.error(message, id))
        }
        return list
    }

    private var startTimes: [UUID: Date] {
        guard let p = preview, let plan = p.plan else { return [:] }
        var out: [UUID: Date] = [:]
        for (seg, proj) in zip(plan.segments, p.projected) where seg.iteration == 0 && out[seg.actionID] == nil {
            out[seg.actionID] = proj.start
        }
        return out
    }

    var body: some View {
        NavigationStack {
            List {
                headerSection
                stepsSection
                scheduleSection
                speedSection
                previewSection
            }
            .environment(\.editMode, $editMode)
            .navigationTitle(isNew ? "New Run" : "Edit Run")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if hasChanges && !isNew { confirmDiscard = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        save()
                        runs.start(draft.id)
                    } label: {
                        Label("Save & Run Now", systemImage: "play.fill")
                            .font(.headline)
                    }
                    .locusProminentButton()
                    .disabled(issues.hasErrors || runs.isActive || preview?.error != nil)
                }
            }
            .confirmationDialog("Discard changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { dismiss() }
            }
            .sheet(isPresented: $showAddAction) {
                AddActionSheet { kind in
                    let action = RunAction(kind)
                    withAnimation(.snappy) { draft.insertAction(action) }
                    if needsImmediateEditing(kind) { editingAction = action }
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(item: $editingAction) { action in
                ActionEditorSheet(
                    action: action,
                    index: draft.actions.firstIndex { $0.id == action.id } ?? draft.actions.count,
                    unit: runs.unit
                ) { updated in
                    if let i = draft.actions.firstIndex(where: { $0.id == updated.id }) {
                        draft.actions[i] = updated
                    }
                }
            }
            .sheet(isPresented: $showTimeline) {
                if let preview {
                    NavigationStack {
                        RunTimelineView(preview: preview, timeZone: draft.timeZone, unit: runs.unit)
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) { Button("Done") { showTimeline = false } }
                            }
                    }
                }
            }
            .task(id: draft) {
                // Debounce: re-route and re-time shortly after edits stop.
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard !Task.isCancelled else { return }
                isPreviewing = true
                let result = await runs.preview(draft)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    preview = result
                    isPreviewing = false
                }
            }
        }
        .interactiveDismissDisabled(hasChanges && !isNew)
    }

    // MARK: Sections

    private var headerSection: some View {
        Section {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(RunsStyle.tint(draft.tint).gradient)
                    .frame(width: 40, height: 40)
                    .overlay(Image(systemName: "calendar.badge.clock").foregroundStyle(.white).font(.headline))
                TextField("Run name", text: $draft.name)
                    .font(.title3.weight(.semibold))
                    .focused($nameFocused)
                    .submitLabel(.done)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(RunsStyle.tints.indices, id: \.self) { i in
                        Button {
                            draft.tint = i
                        } label: {
                            Circle()
                                .fill(RunsStyle.tints[i])
                                .frame(width: 28, height: 28)
                                .overlay(Circle().stroke(.white, lineWidth: draft.tint == i ? 3 : 0))
                                .padding(2)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Color \(i + 1)")
                        .accessibilityAddTraits(draft.tint == i ? .isSelected : [])
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var stepsSection: some View {
        Section {
            if draft.actions.isEmpty {
                Text("Add steps to build your run. They play top to bottom.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(draft.actions.enumerated()), id: \.element.id) { index, action in
                ActionBlockRow(
                    action: action,
                    number: index + 1,
                    isLast: index == draft.actions.count - 1,
                    startTime: startTimes[action.id],
                    timeZone: draft.timeZone,
                    issues: issuesFor(action.id),
                    unit: runs.unit
                )
                .contentShape(Rectangle())
                .onTapGesture { if editMode == .inactive { editingAction = action } }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        withAnimation { draft.deleteAction(id: action.id) }
                    } label: { Label("Delete", systemImage: "trash") }
                    Button {
                        withAnimation { _ = draft.duplicateAction(id: action.id) }
                    } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                    .tint(.indigo)
                }
                .contextMenu {
                    Button { editingAction = action } label: { Label("Edit", systemImage: "pencil") }
                    Button { withAnimation { _ = draft.duplicateAction(id: action.id) } } label: {
                        Label("Duplicate", systemImage: "plus.square.on.square")
                    }
                    if index > 0 {
                        Button { withAnimation { draft.moveActions(fromOffsets: IndexSet(integer: index), toOffset: index - 1) } } label: {
                            Label("Move Up", systemImage: "arrow.up")
                        }
                    }
                    if index < draft.actions.count - 1 {
                        Button { withAnimation { draft.moveActions(fromOffsets: IndexSet(integer: index), toOffset: index + 2) } } label: {
                            Label("Move Down", systemImage: "arrow.down")
                        }
                    }
                    Button(role: .destructive) { withAnimation { draft.deleteAction(id: action.id) } } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
            }
            .onMove { from, to in
                withAnimation { draft.moveActions(fromOffsets: from, toOffset: to) }
            }
            .onDelete { offsets in
                draft.actions.remove(atOffsets: offsets)
            }

            Button {
                showAddAction = true
            } label: {
                Label("Add Action", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .foregroundStyle(LocusTheme.accent)
            }
            .listRowSeparator(.hidden)
        } header: {
            HStack {
                Text("Steps")
                Spacer()
                if draft.actions.count > 1 {
                    Button(editMode == .active ? "Done" : "Reorder") {
                        withAnimation { editMode = editMode == .active ? .inactive : .active }
                    }
                    .font(.caption.weight(.semibold))
                    .textCase(nil)
                }
            }
        } footer: {
            Text("Tap a step to edit it. Long-press for more, or swipe to delete or duplicate.")
        }
    }

    private var scheduleSection: some View {
        Section {
            ScheduleEditor(schedule: $draft.schedule, latePolicy: $draft.latePolicy, isEnabled: $draft.isEnabled)
        } header: {
            Text("Schedule")
        } footer: {
            if draft.schedule.isAutomatic {
                Text("Scheduled runs start on time while Locus is running. If iOS has closed Locus, you'll get a notification and the run starts late when you open the app (within the late-start window).")
            }
        }
    }

    private var speedSection: some View {
        Section {
            NavigationLink {
                Form {
                    SpeedPolicyEditor(policy: $draft.defaultSpeed, unit: runs.unit, referenceSource: firstDriveReferenceSource)
                }
                .navigationTitle("Default Speed")
            } label: {
                LabeledContent("Default speed", value: draft.defaultSpeed.summary(unit: runs.unit))
            }
            Toggle("Smooth acceleration", isOn: $draft.motion.smoothing)
            Toggle("Slow down for turns", isOn: $draft.motion.slowForTurns)
            Picker("Units", selection: $runs.unit) {
                ForEach(SpeedUnit.allCases) { u in Text(u.label).tag(u) }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Speed")
        } footer: {
            Text("Applies to drives until a Set Speed step changes it. A drive with its own custom speed ignores both. Drives always ease to a stop at the destination.")
        }
    }

    private var firstDriveReferenceSource: SpeedReferenceSource? {
        guard let plan = preview?.plan else { return nil }
        for s in plan.segments {
            if case .drive(let leg) = s.kind { return leg.profile.referenceSource }
        }
        return nil
    }

    private var previewSection: some View {
        Section {
            if let error = preview?.error {
                Label(error, systemImage: "exclamationmark.octagon.fill")
                    .foregroundStyle(LocusTheme.danger)
                    .font(.subheadline)
            }
            ForEach(runLevelIssues) { issue in
                IssueLabel(issue: issue)
            }
            if let p = preview, let plan = p.plan {
                let fmt = RunFormat(unit: runs.unit)
                HStack {
                    summaryStat(RunFormat.duration(p.estimatedDuration ?? 0), "Duration")
                    Divider()
                    summaryStat(fmt.distance(plan.totalDriveDistance), "Driving")
                    Divider()
                    summaryStat(RunFormat.time(p.startDate.addingTimeInterval(p.estimatedDuration ?? 0), timeZone: draft.timeZone), "Ends")
                }
                .frame(maxWidth: .infinity)
                if let src = firstDriveReferenceSource, src.isFallback {
                    Label(src.label, systemImage: "gauge.with.dots.needle.33percent")
                        .font(.caption)
                        .foregroundStyle(LocusTheme.statusWarn)
                }
                Button {
                    showTimeline = true
                } label: {
                    Label("Timeline & Route Preview", systemImage: "list.bullet.below.rectangle")
                }
            } else if isPreviewing || preview == nil, !issues.hasErrors {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Calculating routes and timing…").foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
        } header: {
            HStack {
                Text("Preview")
                if isPreviewing && preview != nil {
                    ProgressView().controlSize(.mini)
                }
            }
        } footer: {
            if let p = preview, p.plan != nil {
                Text("Timed as if it starts \(RunFormat.dayAndTime(p.startDate, timeZone: draft.timeZone)). Driving times include acceleration, turns and stopping.")
            }
        }
    }

    private func summaryStat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func needsImmediateEditing(_ kind: RunActionKind) -> Bool {
        switch kind {
        case .stopSpoofing: return false
        default: return true
        }
    }

    private func save() {
        var r = draft
        r.name = r.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.name.isEmpty { r.name = "Untitled Run" }
        draft = r
        runs.save(r)
        dismiss()
    }
}

struct IssueLabel: View {
    let issue: RunIssue

    var body: some View {
        Label {
            Text(issue.message).font(.caption)
        } icon: {
            Image(systemName: issue.severity == .error ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(issue.severity == .error ? LocusTheme.danger : LocusTheme.statusWarn)
        }
    }
}

// MARK: - Schedule

struct ScheduleEditor: View {
    @Binding var schedule: RunSchedule
    @Binding var latePolicy: LatePolicy
    @Binding var isEnabled: Bool

    private enum Mode: String, CaseIterable, Identifiable {
        case manual = "Manual", once = "Once", repeating = "Repeat"
        var id: String { rawValue }
    }

    private var mode: Binding<Mode> {
        Binding {
            switch schedule {
            case .manual: return .manual
            case .once: return .once
            case .recurring: return .repeating
            }
        } set: { m in
            switch m {
            case .manual: schedule = .manual
            case .once: schedule = .once(Date().addingTimeInterval(3600))
            case .repeating: schedule = .recurring(TimeOfDay(hour: 9, minute: 0), weekdays: RunSchedule.weekdaysOnly, timeZoneID: nil)
            }
        }
    }

    var body: some View {
        Picker("When", selection: mode) {
            ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)

        switch schedule {
        case .manual:
            Text("Runs only when you tap Run.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .once(let date):
            DatePicker("Starts", selection: Binding(get: { date }, set: { schedule = .once($0) }), in: Date()...)
            enabledToggle
            latePicker
        case .recurring(let time, let days, let tz):
            DatePicker(
                "Time",
                selection: Binding(
                    get: { Self.date(for: time) },
                    set: { d in
                        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                        schedule = .recurring(TimeOfDay(hour: c.hour ?? 0, minute: c.minute ?? 0), weekdays: days, timeZoneID: tz)
                    }
                ),
                displayedComponents: .hourAndMinute
            )
            WeekdayPicker(days: Binding(get: { days }, set: { schedule = .recurring(time, weekdays: $0, timeZoneID: tz) }))
            NavigationLink {
                TimeZonePicker(identifier: Binding(get: { tz }, set: { schedule = .recurring(time, weekdays: days, timeZoneID: $0) }))
            } label: {
                LabeledContent("Time zone", value: tz.flatMap { TimeZone(identifier: $0)?.identifier } ?? "Device (\(TimeZone.current.identifier))")
            }
            enabledToggle
            latePicker
        }
    }

    private var enabledToggle: some View {
        Toggle("Schedule on", isOn: $isEnabled)
    }

    private var latePicker: some View {
        Picker("If Locus wasn't running", selection: $latePolicy.maxDelay) {
            Text("Skip").tag(0.0)
            Text("Start up to 5 min late").tag(300.0)
            Text("Start up to 15 min late").tag(900.0)
            Text("Start up to 1 h late").tag(3600.0)
        }
    }

    static func date(for t: TimeOfDay) -> Date {
        Calendar.current.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: Date()) ?? Date()
    }
}

struct WeekdayPicker: View {
    @Binding var days: Set<Int>

    var body: some View {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        let first = Calendar.current.firstWeekday
        let order = (0..<7).map { ((first - 1 + $0) % 7) + 1 }
        HStack(spacing: 6) {
            ForEach(order, id: \.self) { d in
                let on = days.contains(d)
                Button {
                    if on { days.remove(d) } else { days.insert(d) }
                } label: {
                    Text(symbols[d - 1])
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .foregroundStyle(on ? .black : .primary)
                        .background(Circle().fill(on ? LocusTheme.accent : Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Calendar.current.weekdaySymbols[d - 1])
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}

struct TimeZonePicker: View {
    @Binding var identifier: String?
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private var zones: [String] {
        let all = TimeZone.knownTimeZoneIdentifiers
        guard !query.isEmpty else { return all }
        return all.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            Button {
                identifier = nil
                dismiss()
            } label: {
                HStack {
                    Text("Follow device time zone")
                    Spacer()
                    if identifier == nil { Image(systemName: "checkmark").foregroundStyle(LocusTheme.accent) }
                }
            }
            ForEach(zones, id: \.self) { z in
                Button {
                    identifier = z
                    dismiss()
                } label: {
                    HStack {
                        Text(z.replacingOccurrences(of: "_", with: " "))
                        Spacer()
                        Text(TimeZone(identifier: z)?.abbreviation() ?? "").foregroundStyle(.secondary).font(.caption)
                        if identifier == z { Image(systemName: "checkmark").foregroundStyle(LocusTheme.accent) }
                    }
                }
                .foregroundStyle(.primary)
            }
        }
        .searchable(text: $query)
        .navigationTitle("Time Zone")
    }
}
