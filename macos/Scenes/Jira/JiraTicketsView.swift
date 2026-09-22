import SwiftUI

struct JiraTicketsView: View {
    @Bindable var model: JiraTicketsViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Keywords, ticket key, or JQL", text: $model.query)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("jira-query")
                    .onSubmit { Task { await model.search() } }
                Button("Search Jira") { Task { await model.search() } }
                if model.searching { ProgressView().controlSize(.small) }
                if model.searchedQuery != nil || !model.query.isEmpty { Button("Clear Search", action: model.clearSearch) }
            }
            if let query = model.searchedQuery { Text("Search results: \(query)").font(.caption).foregroundStyle(.secondary) }
            HStack {
                TextField("Filter loaded tickets", text: Binding(get: { model.filterText }, set: model.setFilterText)).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("jira-filter")
                if model.loading { ProgressView().controlSize(.small) }
                Button("Refresh Tickets", systemImage: "arrow.clockwise", action: model.retry).labelStyle(.iconOnly)
            }
            HStack {
                ForEach(JiraFacet.allCases) { facet in
                    Picker(facet.label, selection: Binding(get: { model.filters[facet.rawValue] ?? "" }, set: { model.setFilter(facet, $0) })) {
                        Text("All \(facet.label.lowercased())").tag("")
                        ForEach(model.options(facet), id: \.self) { value in Text("\(value) (\(model.count(value, facet: facet)))").tag(value) }
                    }.labelsHidden().accessibilityLabel(facet.label)
                }
            }
            if let error = model.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            if let error = model.navigation.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            if let error = model.snapshotError { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            if let error = model.source?.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            if let error = model.preferenceError { Text("Filter preferences: \(error)").foregroundStyle(.orange) }
            if let error = model.siteError { Text(error).foregroundStyle(.orange) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.rows.isEmpty && !model.loading { Text(model.emptyMessage).foregroundStyle(.secondary).padding(.vertical, 20) }
                    ForEach(model.rows) { ticket in
                        HStack(alignment: .top, spacing: 16) {
                            Button(ticket.key) { model.open(ticket) }
                                .buttonStyle(.link).frame(width: 100, alignment: .leading)
                                .accessibilityIdentifier("jira-ticket-\(ticket.key)")
                                .disabled(model.ticketURL(ticket) == nil)
                            if let mark = model.sessionMark(ticket) { PageDestinationMark(mark: mark) }
                            if model.navigation.opening == model.ticketURL(ticket)?.absoluteString && model.navigation.opening != nil {
                                ProgressView().controlSize(.small)
                            }
                            VStack(alignment: .leading, spacing: 5) {
                                Text(ticket.summary ?? "").font(.body.weight(.medium)).textSelection(.enabled)
                                Text([ticket.type, ticket.priority, ticket.assignee].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Menu(ticket.status ?? "Unknown") {
                                ForEach(model.nextStatuses(ticket), id: \.self) { status in
                                    Button(status) { Task { await model.transition(ticket, to: status) } }
                                }
                            }.frame(width: 130).disabled(model.busy.contains(ticket.key) || model.nextStatuses(ticket).isEmpty)
                                .accessibilityIdentifier("jira-status-\(ticket.key)")
                        }.padding(.vertical, 12)
                            .contextMenu {
                                PageRowMenu(hasSession: model.sessionMark(ticket) != nil, open: { model.open(ticket, inTab: true) }, session: { model.openSession(ticket, agent: $0) })
                            }
                        Divider()
                    }
                }
            }
        }.onAppear { model.refresh() }
            .onDisappear(perform: model.cancelActions)
    }
}
