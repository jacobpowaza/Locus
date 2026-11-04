import SwiftUI

/// One block in the builder: number + projected time on a timeline spine,
/// then a card with the action's sentence and parameter tokens.
struct ActionBlockRow: View {
    let action: RunAction
    let number: Int
    let isLast: Bool
    let startTime: Date?
    let timeZone: TimeZone
    let issues: [RunIssue]
    let unit: SpeedUnit

    private var category: RunActionKind.Category { action.kind.category }
    private var color: Color { RunsStyle.color(category) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ActionGlyph(category: category, size: 32)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    sentence
                    Spacer(minLength: 4)
                    Text(startTime.map { RunFormat.time($0, timeZone: timeZone) } ?? "#\(number)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(issues) { IssueLabel(issue: $0) }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number): \(accessibilitySentence)")
        .accessibilityHint("Double-tap to edit")
    }

    @ViewBuilder private var sentence: some View {
        switch action.kind {
        case .setLocation(let p):
            flow { Text("Set location to"); ParamToken(text: p.name, color: color) }
        case .driveTo(let p, let speed):
            flow {
                Text("Drive to")
                ParamToken(text: p.name, color: color)
                if let speed { ParamToken(text: speed.summary(unit: unit), color: RunsStyle.color(.setSpeed)) }
            }
        case .wait(let s):
            flow { Text("Wait"); ParamToken(text: RunFormat.duration(s), color: color) }
        case .startAt(let t, let day):
            flow {
                Text("Start at")
                ParamToken(text: RunFormat.timeOfDay(t), color: color)
                if day > 0 { ParamToken(text: day == 1 ? "next day" : "+\(day) days", color: color) }
            }
        case .setSpeed(let p):
            flow { Text("Set speed to"); ParamToken(text: p.summary(unit: unit), color: color) }
        case .stopSpoofing:
            Text("Stop spoofing").font(.subheadline.weight(.semibold))
        case .repeatPrevious(let count, let times):
            flow {
                Text("Repeat previous")
                ParamToken(text: "\(count) step\(count == 1 ? "" : "s")", color: color)
                ParamToken(text: "\(times)×", color: color)
            }
        }
    }

    private func flow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { content() }
            VStack(alignment: .leading, spacing: 4) { content() }
        }
        .font(.subheadline.weight(.semibold))
    }

    private var detail: String? {
        switch action.kind {
        case .driveTo(_, nil): return "Uses the run's current speed"
        case .stopSpoofing: return "Your iPhone goes back to its real GPS location"
        case .repeatPrevious(_, let times): return "Plays the block \(times + 1) times in total"
        default: return nil
        }
    }

    private var accessibilitySentence: String {
        switch action.kind {
        case .setLocation(let p): return "Set location to \(p.name)"
        case .driveTo(let p, let s): return "Drive to \(p.name)" + (s.map { ", \($0.summary(unit: unit))" } ?? "")
        case .wait(let s): return "Wait \(RunFormat.duration(s))"
        case .startAt(let t, let d): return "Start at \(RunFormat.timeOfDay(t))" + (d > 0 ? ", \(d) day later" : "")
        case .setSpeed(let p): return "Set speed to \(p.summary(unit: unit))"
        case .stopSpoofing: return "Stop spoofing"
        case .repeatPrevious(let c, let t): return "Repeat previous \(c) steps \(t) times"
        }
    }
}

/// Palette of block types.
struct AddActionSheet: View {
    let onPick: (RunActionKind) -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: SpoofSession

    private var here: PlaceRef {
        if let c = session.simulated ?? session.pin ?? session.realCoordinate {
            return PlaceRef(name: session.suggestedFavoriteName(for: c), point: GeoPoint(c))
        }
        return PlaceRef(name: "Choose a place", point: GeoPoint(latitude: .nan, longitude: .nan))
    }

    private var options: [(RunActionKind.Category, RunActionKind)] {
        [
            (.setLocation, .setLocation(here)),
            (.driveTo, .driveTo(PlaceRef(name: "Choose a place", point: GeoPoint(latitude: .nan, longitude: .nan)), speed: nil)),
            (.wait, .wait(seconds: 15 * 60)),
            (.startAt, .startAt(nextHalfHour(), dayOffset: 0)),
            (.setSpeed, .setSpeed(.followLimit)),
            (.stopSpoofing, .stopSpoofing),
            (.repeatPrevious, .repeatPrevious(count: 1, times: 1)),
        ]
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(options.indices, id: \.self) { i in
                    let category = options[i].0
                    let kind = options[i].1
                    Button {
                        onPick(kind)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            ActionGlyph(category: category, size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(RunsStyle.title(category))
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(RunsStyle.blurb(category))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "plus.circle.fill")
                                .font(.title3)
                                .foregroundStyle(RunsStyle.color(category))
                        }
                        .contentShape(Rectangle())
                    }
                }
            }
            .navigationTitle("Add Action")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func nextHalfHour() -> TimeOfDay {
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date().addingTimeInterval(30 * 60))
        let m = (c.minute ?? 0) < 30 ? 30 : 0
        let h = ((c.hour ?? 0) + ((c.minute ?? 0) < 30 ? 0 : 1)) % 24
        return TimeOfDay(hour: h, minute: m)
    }
}

/// Edits one action's parameters.
struct ActionEditorSheet: View {
    let index: Int
    let unit: SpeedUnit
    let onSave: (RunAction) -> Void

    @State private var action: RunAction
    @Environment(\.dismiss) private var dismiss

    init(action: RunAction, index: Int, unit: SpeedUnit, onSave: @escaping (RunAction) -> Void) {
        self.index = index
        self.unit = unit
        self.onSave = onSave
        _action = State(initialValue: action)
    }

    var body: some View {
        NavigationStack {
            Form {
                editor
            }
            .navigationTitle(RunsStyle.title(action.kind.category))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onSave(action)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    @ViewBuilder private var editor: some View {
        switch action.kind {
        case .setLocation(let place):
            PlaceField(place: Binding(get: { place }, set: { action.kind = .setLocation($0) }), title: "Location")
            Section {
                Text("Jumps instantly — no travel time.").font(.footnote).foregroundStyle(.secondary)
            }

        case .driveTo(let place, let speed):
            PlaceField(place: Binding(get: { place }, set: { action.kind = .driveTo($0, speed: speed) }), title: "Destination")
            Section {
                Toggle("Custom speed for this drive", isOn: Binding(
                    get: { speed != nil },
                    set: { action.kind = .driveTo(place, speed: $0 ? .followLimit : nil) }
                ))
            } footer: {
                Text("Off: uses the run's speed (default or the latest Set Speed step).")
            }
            if let speed {
                SpeedPolicyEditor(policy: Binding(get: { speed }, set: { action.kind = .driveTo(place, speed: $0) }), unit: unit, referenceSource: nil)
            }

        case .wait(let seconds):
            DurationEditor(seconds: Binding(get: { seconds }, set: { action.kind = .wait(seconds: $0) }))

        case .startAt(let time, let day):
            Section {
                DatePicker(
                    "Time",
                    selection: Binding(
                        get: { ScheduleEditor.date(for: time) },
                        set: { d in
                            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                            action.kind = .startAt(TimeOfDay(hour: c.hour ?? 0, minute: c.minute ?? 0), dayOffset: day)
                        }
                    ),
                    displayedComponents: .hourAndMinute
                )
                .datePickerStyle(.wheel)
                Picker("Day", selection: Binding(get: { day }, set: { action.kind = .startAt(time, dayOffset: $0) })) {
                    Text("Same day the run starts").tag(0)
                    Text("Next day").tag(1)
                    ForEach(2...6, id: \.self) { Text("\($0) days later").tag($0) }
                }
            } footer: {
                Text("Holds at the current location until this time in the run's time zone. If earlier steps run long, this step starts as soon as they finish and the preview flags it.")
            }

        case .setSpeed(let policy):
            SpeedPolicyEditor(policy: Binding(get: { policy }, set: { action.kind = .setSpeed($0) }), unit: unit, referenceSource: nil)

        case .stopSpoofing:
            Section {
                Text("Ends location simulation. Your iPhone returns to its real GPS location. Add Set Location afterwards to spoof again.")
            }

        case .repeatPrevious(let count, let times):
            Section {
                Stepper(value: Binding(get: { count }, set: { action.kind = .repeatPrevious(count: $0, times: times) }), in: 1...max(1, index)) {
                    LabeledContent("Steps to repeat", value: "\(count)")
                }
                Stepper(value: Binding(get: { times }, set: { action.kind = .repeatPrevious(count: count, times: $0) }), in: 1...RunValidator.maxRepeatTimes) {
                    LabeledContent("Extra times", value: "\(times)")
                }
            } footer: {
                Text("Repeats the \(count) step\(count == 1 ? "" : "s") above this one \(times) more time\(times == 1 ? "" : "s") (\(times + 1) in total). To repeat the whole run on a schedule, use the run's Schedule instead.")
            }
        }
    }
}

/// Hours / minutes / seconds wheels with quick presets.
struct DurationEditor: View {
    @Binding var seconds: Double

    private var h: Int { Int(seconds) / 3600 }
    private var m: Int { (Int(seconds) % 3600) / 60 }
    private var s: Int { Int(seconds) % 60 }

    private func set(h: Int? = nil, m: Int? = nil, s: Int? = nil) {
        let hours: Int = h ?? self.h
        let minutes: Int = m ?? self.m
        let secs: Int = s ?? self.s
        let total: Int = hours * 3600 + minutes * 60 + secs
        seconds = Double(total)
    }

    var body: some View {
        Section {
            HStack(spacing: 0) {
                wheel(0...167, h, "h") { set(h: $0) }
                wheel(0...59, m, "min") { set(m: $0) }
                wheel(0...59, s, "s") { set(s: $0) }
            }
            .frame(height: 150)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach([60.0, 300, 900, 1800, 3600, 7200], id: \.self) { preset in
                        Button(RunFormat.duration(preset)) { seconds = preset }
                            .buttonStyle(LocusChipStyle(selected: seconds == preset))
                    }
                }
            }
        } footer: {
            Text("Stays at the current simulated location for \(RunFormat.duration(seconds)).")
        }
    }

    private func wheel(_ range: ClosedRange<Int>, _ value: Int, _ label: String, _ set: @escaping (Int) -> Void) -> some View {
        Picker(label, selection: Binding(get: { value }, set: set)) {
            ForEach(range, id: \.self) { Text("\($0) \(label)").tag($0) }
        }
        .pickerStyle(.wheel)
        .frame(maxWidth: .infinity)
        .clipped()
    }
}

/// Shows the chosen place and opens the map picker.
struct PlaceField: View {
    @Binding var place: PlaceRef
    let title: String
    @State private var showPicker = false

    var body: some View {
        Section(title) {
            Button {
                showPicker = true
            } label: {
                HStack {
                    Image(systemName: "mappin.circle.fill").font(.title2).foregroundStyle(LocusTheme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(place.point.isValid ? place.name : "Choose a place…")
                            .foregroundStyle(.primary)
                        if place.point.isValid {
                            Text(String(format: "%.5f, %.5f", place.point.latitude, place.point.longitude))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .sheet(isPresented: $showPicker) {
                LocationPickerView(initial: place.point.isValid ? place : nil) { picked in
                    place = picked
                }
            }
            if place.point.isValid {
                TextField("Name", text: $place.name)
            }
        }
    }
}
