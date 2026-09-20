import SwiftUI

/// The web System tab's "Database" card. A Section for a grouped Form — the Form scrolls, so this
/// no longer nests a ScrollView of its own.
struct DiagnosticsView: View {
    let model: DiagnosticsViewModel

    var body: some View {
        Section {
            Text("Reads the saved snapshots. Refreshing this inspector does not run GitHub or Jira commands.")
                .font(.caption).foregroundStyle(Theme.textSecondary)
            if let error = model.error {
                Text(error).foregroundStyle(Theme.danger).textSelection(.enabled)
                if model.snapshot != nil { Text("Showing the last successful read.").foregroundStyle(Theme.textSecondary) }
            }
            if let snapshot = model.snapshot {
                HStack(spacing: 24) {
                    Text("Projects: \(snapshot.counts.projects)")
                    Text("PR–Jira links: \(snapshot.counts.links)")
                    Text("Recent events: \(snapshot.counts.events) (up to 1,000)")
                }.accessibilityIdentifier("diagnostics-counts")
                GroupBox("GitHub CLI · since backend startup") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Calls: \(snapshot.ghStats.calls) · Errors: \(snapshot.ghStats.errors)")
                        Text("Average: \(snapshot.ghStats.avgMs) ms · Maximum: \(snapshot.ghStats.maxMs) ms")
                        Text("Syncs in flight: \(snapshot.ghStats.inflight) · Coalesced: \(snapshot.ghStats.coalesced)")
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
                if model.projects.isEmpty { Text("No projects configured.").foregroundStyle(Theme.textSecondary) }
                ForEach(model.projects) { project in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(project.repository).foregroundStyle(Theme.textSecondary)
                            Text(project.automation).foregroundStyle(Theme.textSecondary)
                            ForEach(project.caches) { cache in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(cache.title).fontWeight(.medium).frame(width: 110, alignment: .leading)
                                        Text(cache.count)
                                        Spacer()
                                        Text(cache.lastSync).foregroundStyle(Theme.textSecondary)
                                    }
                                    if let error = cache.error { Text(error).foregroundStyle(Theme.danger) }
                                }.accessibilityIdentifier("diagnostics-cache-\(project.id)-\(cache.id)")
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    } label: { Text(project.name).fontWeight(.semibold) }
                }
                .textSelection(.enabled)
                if let updatedAt = model.updatedAt {
                    Text("Inspector updated \(updatedAt.formatted(date: .abbreviated, time: .standard))")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
            } else if !model.loading && model.error == nil {
                ContentUnavailableView("Waiting for backend", systemImage: "externaldrive")
            }
        } header: {
            SettingsSectionHeader(title: "Database", busy: model.loading) {
                Button("Refresh", action: model.refresh).disabled(model.loading)
                    .accessibilityIdentifier("diagnostics-refresh")
            }
        }
    }
}
