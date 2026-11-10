import SwiftUI

/// Shared speed controls for route planning, automation and live playback.
/// Values are edited in the user's unit and stored in m/s.
struct SpeedPolicyEditor: View {
    @Binding var policy: SpeedPolicy
    let unit: SpeedUnit
    /// When known (from a preview), explains where "limit" comes from.
    let referenceSource: SpeedReferenceSource?

    private enum Mode: String, CaseIterable, Identifiable {
        case follow = "Follow Speed Limit"
        case above = "Above Speed Limit"
        case timed = "Above for Part of Drive"
        case variable = "Variable Speed"
        case constant = "Constant Speed"
        case below = "Below Speed Limit"
        var id: String { rawValue }
    }

    private var mode: Binding<Mode> {
        Binding {
            switch policy {
            case .followLimit: return .follow
            case .variable: return .variable
            case .constant: return .constant
            case .aboveLimit, .aboveLimitPercent: return .above
            case .aboveLimitForTime: return .timed
            case .belowLimit: return .below
            }
        } set: { m in
            switch m {
            case .follow: policy = .followLimit
            case .variable: policy = .variable
            case .constant: policy = .constant(unit.toMetersPerSecond(unit == .mph ? 35 : 50))
            case .above: policy = .aboveLimit(unit.toMetersPerSecond(5))
            case .timed: policy = .aboveLimitForTime(offset: unit.toMetersPerSecond(5), percent: 30)
            case .below: policy = .belowLimit(unit.toMetersPerSecond(5))
            }
        }
    }

    /// Value in display units for constant / offset modes.
    private var displayValue: Binding<Double> {
        Binding {
            switch policy {
            case .followLimit, .variable: return 0
            case .aboveLimitPercent(let p), .aboveLimitForTime(_, let p): return p
            case .constant(let v), .aboveLimit(let v), .belowLimit(let v): return unit.fromMetersPerSecond(v).rounded()
            }
        } set: { newValue in
            let mps = unit.toMetersPerSecond(newValue)
            switch policy {
            case .followLimit, .variable: break
            case .constant: policy = .constant(mps)
            case .aboveLimit: policy = .aboveLimit(mps)
            case .aboveLimitPercent: policy = .aboveLimitPercent(newValue)
            case .aboveLimitForTime(let offset, _): policy = .aboveLimitForTime(offset: offset, percent: newValue)
            case .belowLimit: policy = .belowLimit(mps)
            }
        }
    }

    private var range: ClosedRange<Double> {
        switch policy {
        case .aboveLimitPercent, .aboveLimitForTime: return 0...100
        case .constant: return unit == .mph ? 1...120 : 2...190
        default: return 0...(unit == .mph ? 25 : 40)
        }
    }

    var body: some View {
        Section {
            Picker("Speed", selection: mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }

            if mode.wrappedValue == .above {
                Picker("Offset type", selection: percentage) {
                    Text("Fixed").tag(false)
                    Text("Percentage").tag(true)
                }
                .pickerStyle(.segmented)
            }

            switch policy {
            case .followLimit:
                Label("Uses posted limits where available.", systemImage: "road.lanes")
                    .font(.subheadline)
            case .variable:
                Label("Varies speed along the route and slows for turns and stops.", systemImage: "waveform.path")
                    .font(.subheadline)
            case .constant, .aboveLimit, .aboveLimitPercent, .aboveLimitForTime, .belowLimit:
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(valueTitle).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(displayValue.wrappedValue))")
                            .font(.title2.weight(.bold).monospacedDigit())
                            .contentTransition(.numericText())
                        Text(percentage.wrappedValue || mode.wrappedValue == .timed ? "%" : unit.label).foregroundStyle(.secondary)
                    }
                    Slider(value: displayValue, in: range, step: 1)
                        .tint(LocusTheme.accent)
                        .accessibilityLabel(valueTitle)
                }
                .animation(.snappy, value: displayValue.wrappedValue)
            }
            if case .aboveLimitForTime(let offset, let percent) = policy {
                Stepper(value: Binding(
                    get: { unit.fromMetersPerSecond(offset).rounded() },
                    set: { policy = .aboveLimitForTime(offset: unit.toMetersPerSecond($0), percent: percent) }
                ), in: 1...(unit == .mph ? 25 : 40)) {
                    LabeledContent("Over the Limit By", value: RunFormat(unit: unit).speed(offset))
                }
            }
        } header: {
            Text("Speed")
        } footer: {
            Text(footer)
        }
    }

    private var percentage: Binding<Bool> {
        Binding {
            if case .aboveLimitPercent = policy { return true }
            return false
        } set: { enabled in
            policy = enabled ? .aboveLimitPercent(10) : .aboveLimit(unit.toMetersPerSecond(5))
        }
    }

    private var valueTitle: String {
        switch policy {
        case .constant: return "Speed"
        case .aboveLimit, .aboveLimitPercent: return "Over the limit by"
        case .aboveLimitForTime: return "Target share of cruising time"
        case .belowLimit: return "Under the limit by"
        case .followLimit, .variable: return ""
        }
    }

    private var footer: String {
        if !policy.usesReference {
            return "Holds this speed where the road allows, still slowing for turns."
        }
        if case .aboveLimitForTime = policy {
            return "Targets this share of cruising time on roads with posted limits. Turns, stops, and speed zones can change the actual share."
        }
        return referenceSource?.explanation
            ?? "Locus checks the route against OpenStreetMap for posted limits. Speed offsets apply only where a limit is available."
    }
}
