import SwiftUI

/// The dashboard's global search, standing in for whichever page is up while the toolbar's field
/// holds text: the user's own matching pull requests, matching review requests, then matching
/// tickets, each only when it has a match. Clearing the search returns to the page underneath.
struct DashboardSearchView: View {
    @Bindable var model: DashboardViewModel

    var body: some View {
        let search = model.search
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                DashboardPageHeader(caption: search.caption, title: "Search")
                    .padding(.top, 12).padding(.bottom, 24)
                if let error = model.navigation.error { warning(error) }
                if search.isEmpty {
                    empty
                } else {
                    VStack(alignment: .leading, spacing: 40) {
                        if !search.mine.isEmpty { pullRequests("Your pull requests", search.mine) }
                        if !search.reviews.isEmpty { pullRequests("Review requests", search.reviews) }
                        if !search.tickets.isEmpty { tickets(search.tickets) }
                    }
                }
            }
            .padding(.horizontal, 28).padding(.top, 16).padding(.bottom, 40)
        }
        .accessibilityIdentifier("dashboard-search")
    }

    private func pullRequests(_ title: String, _ rows: [DashboardRow]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            DashboardSectionHeader(title: title, detail: "")
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in prRow(row, first: index == 0) }
        }
    }

    private func prRow(_ row: DashboardRow, first: Bool) -> some View {
        let mark = model.sessionMark(row)
        return DashboardPRRow(row: row, mark: mark, opening: model.navigation.opening == row.url.absoluteString,
                              first: first, open: { model.open(row) })
            .contextMenu {
                PageRowMenu(hasSession: mark != nil, open: { model.open(row, inTab: true) },
                            session: { model.openSession(row, agent: $0) })
            }
    }

    private func tickets(_ rows: [DashboardTicketRow]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            DashboardSectionHeader(title: "Tickets", detail: "")
            DashboardTicketTable(rows: rows, opening: model.navigation.opening,
                open: { model.open($0) }, openTab: { model.open($0, inTab: true) },
                session: { model.openSession($0, agent: $1) }, sessionMark: model.sessionMark)
        }
    }

    private var empty: some View {
        VStack(spacing: 5) {
            Text("Nothing matches “\(model.search.needle)”").font(.system(size: 13, weight: .semibold)).foregroundStyle(DashboardPalette.ink2)
            Button("Clear the search", action: model.clearFilter).buttonStyle(.link).font(.system(size: 12))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
    }

    private func warning(_ text: String) -> some View {
        HStack(spacing: 8) {
            Label(text, systemImage: "exclamationmark.triangle.fill"); Spacer()
        }.font(.callout).foregroundStyle(.orange).padding(10)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8)).padding(.bottom, 12)
    }
}
