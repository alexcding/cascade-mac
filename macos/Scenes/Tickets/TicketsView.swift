import SwiftUI

struct TicketsView: View {
    @Bindable var model: TicketsViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField(model.source.searchPrompt, text: $model.query)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("\(model.source.rawValue)-query")
                    .onSubmit { Task { await model.search() } }
                Button(model.source.searchTitle) { Task { await model.search() } }
                if model.searching { ProgressView().controlSize(.small) }
                if model.searchedQuery != nil || !model.query.isEmpty { Button("Clear Search", action: model.clearSearch) }
            }
            if let query = model.searchedQuery { Text("Search results: \(query)").font(.caption).foregroundStyle(.secondary) }
            HStack {
                TextField("Filter loaded tickets", text: Binding(get: { model.filterText }, set: model.setFilterText)).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("\(model.source.rawValue)-filter")
                if model.loading { ProgressView().controlSize(.small) }
                Button("Refresh Tickets", systemImage: "arrow.clockwise", action: model.retry).labelStyle(.iconOnly)
            }
            HStack {
                ForEach(model.source.facets) { facet in
                    Picker(facet.label, selection: Binding(get: { model.filters[facet.rawValue] ?? "" }, set: { model.setFilter(facet, $0) })) {
                        Text(facet.allLabel).tag("")
                        ForEach(model.options(facet), id: \.self) { value in Text("\(value) (\(model.count(value, facet: facet)))").tag(value) }
                    }.labelsHidden().accessibilityLabel(facet.label)
                }
            }
            if let error = model.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            if let error = model.navigation.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            if let error = model.snapshotError { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            if let error = model.shown?.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            if let error = model.preferenceError { Text("Filter preferences: \(error)").foregroundStyle(.orange) }
            if let error = model.siteError { Text(error).foregroundStyle(.orange) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.rows.isEmpty && !model.loading { Text(model.emptyMessage).foregroundStyle(.secondary).padding(.vertical, 20) }
                    ForEach(model.rows) { ticket in
                        HStack(alignment: .top, spacing: 16) {
                            Button(ticket.key) { model.open(ticket) }
                                .buttonStyle(.link).frame(width: 100, alignment: .leading)
                                .accessibilityIdentifier("\(model.source.rawValue)-ticket-\(ticket.key)")
                                .disabled(model.ticketURL(ticket) == nil)
                            if let mark = model.sessionMark(ticket) { PageDestinationMark(mark: mark) }
                            if model.navigation.opening == model.ticketURL(ticket)?.absoluteString && model.navigation.opening != nil {
                                ProgressView().controlSize(.small)
                            }
                            VStack(alignment: .leading, spacing: 5) {
                                Text(ticket.summary ?? "").font(.body.weight(.medium)).textSelection(.enabled)
                                Text(detail(ticket)).font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Menu(ticket.status ?? String(localized: "Unknown")) {
                                ForEach(model.nextStatuses(ticket), id: \.self) { status in
                                    Button(status) { Task { await model.transition(ticket, to: status) } }
                                }
                            }.frame(width: 130).disabled(model.busy.contains(ticket.id) || model.nextStatuses(ticket).isEmpty)
                                .accessibilityIdentifier("\(model.source.rawValue)-status-\(ticket.key)")
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

    /// The row's second line: type, priority and assignee for Jira; type, labels and assignee for an issue.
    private func detail(_ ticket: Ticket) -> String {
        let middle: [String?] = model.source == .github ? (ticket.labels ?? []).prefix(3).map { $0 } : [ticket.priority]
        return ([ticket.type] + middle + [ticket.assignee]).compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
