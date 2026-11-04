import SwiftUI

/// Speed configuration panel: Follow / Constant / Above / Below limit.
/// Values are edited in the user's unit and stored in m/s.
struct SpeedPolicyEditor: View {
    @Binding var policy: SpeedPolicy
    let unit: SpeedUnit
    /// When known (from a preview), explains where "limit" comes from.
    let referenceSource: SpeedReferenceSource?

    private enum Mode: String, CaseIterable, Identifiable {
        case follow = "At Limit", above = "Faster", below = "Slower", constant = "Fixed"
        var id: String { rawValue }
    }

    private var mode: Binding<Mode> {
        Binding {
            switch policy {
            case .followLimit: return .follow
            case .constant: return .constant
            case .aboveLimit: return .above
            case .belowLimit: return .below
            }
        } set: { m in
            switch m {
            case .follow: policy = .followLimit
            case .constant: policy = .constant(unit.toMetersPerSecond(unit == .mph ? 35 : 50))
            case .above: policy = .aboveLimit(unit.toMetersPerSecond(5))
            case .below: policy = .belowLimit(unit.toMetersPerSecond(5))
            }
        }
    }

    /// Value in display units for constant / offset modes.
    private var displayValue: Binding<Double> {
        Binding {
            switch policy {
            case .followLimit: return 0
            case .constant(let v), .aboveLimit(let v), .belowLimit(let v): return unit.fromMetersPerSecond(v).rounded()
            }
        } set: { newValue in
            let mps = unit.toMetersPerSecond(newValue)
            switch policy {
            case .followLimit: break
            case .constant: policy = .constant(mps)
            case .aboveLimit: policy = .aboveLimit(mps)
            case .belowLimit: policy = .belowLimit(mps)
            }
        }
    }

    private var range: ClosedRange<Double> {
        switch policy {
        case .constant: return unit == .mph ? 1...120 : 2...190
        default: return 0...(unit == .mph ? 25 : 40)
        }
    }

    var body: some View {
        Section {
            Picker("Speed", selection: mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            switch policy {
            case .followLimit:
                Label("Drives at the usual speed for each road.", systemImage: "road.lanes")
                    .font(.subheadline)
            case .constant, .aboveLimit, .belowLimit:
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(valueTitle).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(displayValue.wrappedValue))")
                            .font(.title2.weight(.bold).monospacedDigit())
                            .contentTransition(.numericText())
                        Text(unit.label).foregroundStyle(.secondary)
                    }
                    Slider(value: displayValue, in: range, step: 1)
                        .tint(LocusTheme.accent)
                }
                .animation(.snappy, value: displayValue.wrappedValue)
            }
        } header: {
            Text("Speed")
        } footer: {
            Text(footer)
        }
    }

    private var valueTitle: String {
        switch policy {
        case .constant: return "Speed"
        case .aboveLimit: return "Over the limit by"
        case .belowLimit: return "Under the limit by"
        case .followLimit: return ""
        }
    }

    private var footer: String {
        if !policy.usesReference {
            return "Holds this speed where the road allows, still slowing for turns."
        }
        if referenceSource == .postedLimits { return "Follows posted speed limits." }
        return "Apple Maps doesn't share posted limits, so Locus uses the route's typical speed."
    }
}
