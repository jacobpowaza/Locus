import SwiftUI

/// Visual vocabulary for Scheduled Runs, built on LocusTheme.
enum RunsStyle {
    /// Tile tints for runs (index stored on ScheduledRun.tint).
    static let tints: [Color] = [
        LocusTheme.accent,
        Color(red: 0.36, green: 0.55, blue: 0.98),
        LocusTheme.accentSecondary,
        Color(red: 0.62, green: 0.45, blue: 0.95),
        Color(red: 0.95, green: 0.42, blue: 0.62),
        Color(red: 0.55, green: 0.80, blue: 0.35),
    ]

    static func tint(_ index: Int) -> Color { tints[((index % tints.count) + tints.count) % tints.count] }

    static func color(_ c: RunActionKind.Category) -> Color {
        switch c {
        case .setLocation: return LocusTheme.accent
        case .driveTo: return Color(red: 0.36, green: 0.55, blue: 0.98)
        case .wait: return Color(red: 0.55, green: 0.58, blue: 0.68)
        case .startAt: return LocusTheme.accentSecondary
        case .setSpeed: return Color(red: 0.62, green: 0.45, blue: 0.95)
        case .stopSpoofing: return LocusTheme.danger
        case .repeatPrevious: return Color(red: 0.92, green: 0.74, blue: 0.25)
        }
    }

    static func icon(_ c: RunActionKind.Category) -> String {
        switch c {
        case .setLocation: return "mappin.and.ellipse"
        case .driveTo: return "car.fill"
        case .wait: return "hourglass"
        case .startAt: return "clock.fill"
        case .setSpeed: return "gauge.with.dots.needle.67percent"
        case .stopSpoofing: return "location.slash.fill"
        case .repeatPrevious: return "repeat"
        }
    }

    static func title(_ c: RunActionKind.Category) -> String {
        switch c {
        case .setLocation: return "Teleport"
        case .driveTo: return "Drive To"
        case .wait: return "Wait"
        case .startAt: return "Wait Until"
        case .setSpeed: return "Change Speed"
        case .stopSpoofing: return "Turn Off Locus"
        case .repeatPrevious: return "Repeat"
        }
    }

    static func blurb(_ c: RunActionKind.Category) -> String {
        switch c {
        case .setLocation: return "Appear somewhere instantly"
        case .driveTo: return "Drive there on real roads"
        case .wait: return "Stay put for a while"
        case .startAt: return "Stay put until a time of day"
        case .setSpeed: return "Drive faster or slower from here on"
        case .stopSpoofing: return "Go back to your real location"
        case .repeatPrevious: return "Do earlier steps again"
        }
    }
}

/// Formatting in the user's units and locale.
struct RunFormat {
    var unit: SpeedUnit

    func speed(_ mps: Double) -> String {
        "\(Int(unit.fromMetersPerSecond(mps).rounded())) \(unit.label)"
    }

    func speedNumber(_ mps: Double) -> String {
        "\(Int(unit.fromMetersPerSecond(mps).rounded()))"
    }

    func distance(_ meters: Double) -> String {
        let v = meters / unit.metersPerDistanceUnit
        if v < 0.1 {
            return unit == .mph ? "\(Int((meters * 3.28084 / 10).rounded()) * 10) ft" : "\(Int(meters.rounded())) m"
        }
        return String(format: v < 10 ? "%.1f %@" : "%.0f %@", v, unit.distanceLabel)
    }

    /// Travel-time style: "8 min", "1 hr 20 min".
    static func eta(_ seconds: Double) -> String {
        let f = DateComponentsFormatter()
        f.unitsStyle = .short
        f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        f.maximumUnitCount = 2
        let rounded = max(60, (seconds / 60).rounded() * 60)
        return f.string(from: rounded) ?? DurationText.short(seconds)
    }

    static func duration(_ seconds: Double) -> String {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : (seconds >= 60 ? [.minute, .second] : [.second])
        f.maximumUnitCount = 2
        return f.string(from: max(0, seconds.rounded())) ?? DurationText.short(seconds)
    }

    static func time(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.timeZone = timeZone
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: date)
    }

    static func dayAndTime(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.timeZone = timeZone
        f.doesRelativeDateFormatting = true
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    static func timeOfDay(_ t: TimeOfDay) -> String {
        var c = DateComponents()
        c.hour = t.hour
        c.minute = t.minute
        let d = Calendar.current.date(from: c) ?? Date()
        return time(d)
    }

    static func schedule(_ s: RunSchedule) -> String {
        switch s {
        case .manual:
            return "Run manually"
        case .once(let d):
            return "Once · \(dayAndTime(d))"
        case .recurring(let t, let days, let tz):
            let dayText: String
            if days == RunSchedule.everyDay {
                dayText = "Every day"
            } else if days == RunSchedule.weekdaysOnly {
                dayText = "Weekdays"
            } else if days == [1, 7] {
                dayText = "Weekends"
            } else {
                let symbols = Calendar.current.shortWeekdaySymbols
                dayText = days.sorted().map { symbols[$0 - 1] }.joined(separator: ", ")
            }
            let tzText = tz.flatMap { TimeZone(identifier: $0) }.map { $0 == .current ? "" : " (\($0.abbreviation() ?? $0.identifier))" } ?? ""
            return "\(dayText) · \(timeOfDay(t))\(tzText)"
        }
    }
}

// MARK: - Controls that match the map tray (Teleport / Joy / Stop)

/// Capsule button in the same vocabulary as the map's bottom tray:
/// teal fill + black label for the main action, a faint fill for secondary
/// ones, red for stop/end.
struct LocusPillButtonStyle: ButtonStyle {
    enum Role { case primary, secondary, danger }
    var role: Role = .secondary
    var expand = false

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, role: role, expand: expand)
    }

    private struct PillBody: View {
        let configuration: ButtonStyleConfiguration
        let role: Role
        let expand: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.subheadline.weight(role == .secondary ? .semibold : .bold))
                .lineLimit(1)
                .foregroundStyle(foreground)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: expand ? .infinity : nil)
                .background(Capsule().fill(fill))
                .contentShape(Capsule())
                .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.snappy(duration: 0.15), value: configuration.isPressed)
        }

        private var fill: Color {
            switch role {
            case .primary: return LocusTheme.accent
            case .secondary: return Color.primary.opacity(0.08)
            case .danger: return LocusTheme.danger
            }
        }

        private var foreground: Color {
            switch role {
            case .primary: return .black
            case .secondary: return .primary
            case .danger: return .white
            }
        }
    }
}

/// 44 pt round icon button, like the tray's settings / favorites buttons.
struct LocusRoundButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RoundBody(configuration: configuration)
    }

    private struct RoundBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.primary.opacity(0.08)))
                .contentShape(Circle())
                .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
                .animation(.snappy(duration: 0.15), value: configuration.isPressed)
        }
    }
}

/// Selectable chip, like the travel-mode picker on the map.
struct LocusChipStyle: ButtonStyle {
    var selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(selected ? Color.black : Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(selected ? LocusTheme.accent : Color.primary.opacity(0.08)))
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

extension View {
    /// System prominent button: Liquid Glass on iOS 26, bordered before.
    @ViewBuilder
    func locusProminentButton() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent).tint(LocusTheme.accent)
        } else {
            self.buttonStyle(.borderedProminent).tint(LocusTheme.accent)
        }
    }

    /// Glass panel used for chrome floating over a map.
    func runGlassPanel(cornerRadius: CGFloat = 20, tint: Color? = nil) -> some View {
        locusGlass(.regular, tint: tint, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// Coloured square icon for an action category.
struct ActionGlyph: View {
    let category: RunActionKind.Category
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: RunsStyle.icon(category))
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(RunsStyle.color(category).gradient)
            )
            .accessibilityHidden(true)
    }
}

/// Small rounded "token" showing an editable parameter inside a block.
struct ParamToken: View {
    let text: String
    var color: Color = LocusTheme.accent

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.16)))
    }
}

/// "Simulated" badge — keeps spoofed data visually distinct from real GPS.
struct SimulatedBadge: View {
    var body: some View {
        Label("Simulated", systemImage: "location.viewfinder")
            .font(.caption2.weight(.bold))
            .textCase(.uppercase)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(LocusTheme.accentSecondary)
            .background(Capsule().fill(LocusTheme.accentSecondary.opacity(0.16)))
            .accessibilityLabel("Simulated location, not real GPS")
    }
}
