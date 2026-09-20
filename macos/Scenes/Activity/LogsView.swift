import SwiftUI

struct LogsView: View {
    @Bindable var model: LogsViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // The categories as inline segments with no title, as the web Settings page had them.
            Picker("Category", selection: $model.category) {
                ForEach(model.categories, id: \.self) { Text(LogsViewModel.label($0)).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().fixedSize()
            HStack {
                Toggle("Errors only", isOn: $model.errorsOnly)
                Spacer()
                Button("Refresh logs", systemImage: "arrow.clockwise", action: model.refresh).labelStyle(.iconOnly)
                Button("Clear Logs…", role: .destructive, action: model.requestClear).disabled(!model.canRequestClear)
            }
            TextField("Search loaded logs", text: $model.search).textFieldStyle(.roundedBorder).accessibilityIdentifier("logs-search")
            if let error = model.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled) }
            if let error = model.navigation.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled) }
            if model.loading { ProgressView("Loading logs…").controlSize(.small) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if model.rows.isEmpty && !model.loading {
                        Text(model.updated == nil ? "Connect to load activity." : "No matching entries.").foregroundStyle(.secondary)
                    }
                    ForEach(model.rows) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Image(systemName: entry.level == "error" ? "exclamationmark.circle" : "clock")
                                    .foregroundStyle(entry.level == "error" ? .red : .secondary)
                                Text(entry.title).font(.headline)
                                Spacer()
                                Text(entry.timestamp).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(entry.detail).font(.callout).textSelection(.enabled)
                            HStack {
                                Text("\(LogsViewModel.label(entry.category)) · \(entry.level)").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                if let link = entry.link {
                                    if model.navigation.opening == link { ProgressView().controlSize(.small) }
                                    Button("Open Pull Request") { model.open(entry) }.disabled(model.navigation.opening == link)
                                }
                                Button("Copy entry", systemImage: "doc.on.doc") { model.copyEntry(entry) }.labelStyle(.iconOnly)
                            }
                        }.accessibilityIdentifier("log-entry-\(entry.id)")
                        Divider()
                    }
                }
            }
            Text("Latest 200 entries for the selected category and level.").font(.caption).foregroundStyle(.secondary)
        }.onAppear(perform: model.refresh)
    }
}
