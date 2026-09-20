import AppKit
import SwiftUI

/// The web System tab's "Resource usage" card. A Section for a grouped Form.
struct ResourceUsageView: View {
    let model: ResourceUsageViewModel
    /// Header plus one default-height row per process, with room for at least three.
    static func tableHeight(rows: Int) -> CGFloat { 36 + CGFloat(max(rows, 3)) * 24 }
    var body: some View {
        Section {
            HStack(spacing: 24) {
                Text("Listed memory: \(model.memory)").accessibilityIdentifier("resources-memory")
                Text("Listed CPU: \(model.cpu)").accessibilityIdentifier("resources-cpu")
            }.monospacedDigit()
            Text("CPU updates every 3 seconds while this view is active; 100% means one CPU core. Memory is physical footprint, the figure Activity Monitor shows.")
                .font(.caption).foregroundStyle(Theme.textSecondary)
            Text("Includes the app, connected backend, PTY helper and their descendants, plus the WebKit and other helper processes macOS runs for the app. Totals cover only listed processes.")
                .font(.caption).foregroundStyle(Theme.textSecondary)
            if let error = model.error {
                Text(error).foregroundStyle(Theme.danger)
                if model.updatedAt != nil { Text("Showing the last successful sample.").foregroundStyle(Theme.textSecondary) }
            }
            ForEach(model.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(Theme.textSecondary) }
            // The Form scrolls, so the table needs an explicit height or it collapses to one row.
            // Size it to its rows: a fixed height cuts the list off behind a second, nested scroll.
            Table(model.rows) {
                TableColumn("Component") { Text($0.process.group.rawValue) }.width(85)
                TableColumn("Process") { Text($0.process.name) }
                TableColumn("PID") { Text(String($0.process.pid)).monospacedDigit() }.width(65)
                TableColumn("Memory") { Text($0.memory).monospacedDigit() }.width(90)
                TableColumn("CPU") { Text($0.cpu).monospacedDigit() }.width(90)
            }.frame(height: Self.tableHeight(rows: model.rows.count)).accessibilityIdentifier("resources-processes")
            if let date = model.updatedAt {
                Text("Sampled \(date.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(Theme.textSecondary)
            }
        } header: {
            SettingsSectionHeader(title: "Resource usage", busy: model.loading) {
                Button("Refresh", action: model.refresh).disabled(model.loading)
                    .accessibilityIdentifier("resources-refresh")
            }
        }
    }
}
