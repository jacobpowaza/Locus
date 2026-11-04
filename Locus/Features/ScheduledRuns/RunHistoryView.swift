import SwiftUI

/// Completed, failed, cancelled and missed runs with their logs.
struct RunHistoryView: View {
    @EnvironmentObject private var runs: ScheduledRunsController
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            List {
                if runs.history.isEmpty {
                    ContentUnavailableView("No runs yet", systemImage: "clock.arrow.circlepath",
                                           description: Text("Finished, failed and missed runs show up here."))
                }
                ForEach(runs.history) { record in
                    NavigationLink {
                        RunRecordDetail(record: record, unit: runs.unit)
                    } label: {
                        HistoryRow(record: record, unit: runs.unit)
                    }
                }
            }
            .navigationTitle("Run History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    ShareLink(item: runs.diagnosticsReport(), preview: SharePreview("Locus diagnostics")) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Export diagnostics")
                    Menu {
                        Button("Clear History", role: .destructive) { confirmClear = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .disabled(runs.history.isEmpty)
                }
            }
            .confirmationDialog("Clear all run history?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear History", role: .destructive) { runs.clearHistory() }
            }
        }
    }
}

struct HistoryRow: View {
    let record: RunRecord
    let unit: SpeedUnit

    private var icon: (String, Color) {
        switch record.outcome {
        case .completed: return ("checkmark.circle.fill", LocusTheme.statusGood)
        case .failed: return ("xmark.octagon.fill", LocusTheme.statusBad)
        case .cancelled: return ("stop.circle.fill", .secondary)
        case .missed: return ("bell.slash.fill", LocusTheme.statusWarn)
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon.0).font(.title3).foregroundStyle(icon.1)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.runName).font(.subheadline.weight(.semibold))
                Text("\(record.outcome.label) · \(RunFormat.dayAndTime(record.occurrence ?? record.startedAt ?? record.endedAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let m = record.message {
                    Text(m).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            if record.distance > 0 {
                Text(RunFormat(unit: unit).distance(record.distance))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct RunRecordDetail: View {
    let record: RunRecord
    let unit: SpeedUnit

    var body: some View {
        List {
            Section {
                HistoryRow(record: record, unit: unit)
                if let s = record.startedAt {
                    LabeledContent("Started", value: RunFormat.dayAndTime(s))
                    LabeledContent("Duration", value: RunFormat.duration(record.endedAt.timeIntervalSince(s)))
                }
                if let o = record.occurrence {
                    LabeledContent("Scheduled for", value: RunFormat.dayAndTime(o))
                }
                LabeledContent("Trigger", value: record.trigger == .scheduled ? "Schedule" : "Manual")
            }
            Section("Log") {
                ForEach(Array(record.log.enumerated()), id: \.offset) { _, entry in
                    HStack(alignment: .top, spacing: 8) {
                        Text(RunFormat.time(entry.date))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 58, alignment: .leading)
                        Image(systemName: entry.level == .error ? "xmark.octagon.fill" : (entry.level == .warning ? "exclamationmark.triangle.fill" : "circle.fill"))
                            .font(.system(size: entry.level == .info ? 6 : 12))
                            .foregroundStyle(entry.level == .error ? LocusTheme.statusBad : (entry.level == .warning ? LocusTheme.statusWarn : .secondary))
                            .frame(width: 14)
                            .padding(.top, entry.level == .info ? 5 : 1)
                        Text(entry.message).font(.caption)
                    }
                }
            }
        }
        .navigationTitle(record.runName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ShareLink(item: record.diagnosticsText(), preview: SharePreview("\(record.runName) log"))
        }
    }
}
