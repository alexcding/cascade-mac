import SwiftUI

/// The board's own filters in the Dashboard's tag style: a JQL clause, applied on Return, and
/// whose cards to show.
struct BoardFilters: View {
    let board: WebBoardViewModel
    @FocusState private var queryFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 10, weight: .bold)).foregroundStyle(DashboardPalette.ink3)
                TextField("Filter, e.g. component = iOS", text: Bindable(board).queryDraft)
                    .textFieldStyle(.plain).font(.system(size: 12.5))
                    .focused($queryFocused)
                    .onSubmit { board.applyQuery() }
                    .onChange(of: queryFocused) { _, focused in board.queryEditing = focused }
            }
            .padding(.horizontal, 10).frame(width: 240, height: 30)
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(queryFocused ? Color.primary.opacity(0.5) : DashboardPalette.buttonBorder, lineWidth: 1))
            .help("A JQL clause ANDed into the board (blank = everything). Return applies.")
            Menu {
                Picker("Assignee", selection: Binding(get: { board.assigneeFilter }, set: board.setAssigneeFilter)) {
                    Text("All assignees").tag("")
                    if board.showsUnassignedFilter { Text("Unassigned").tag(WebBoardViewModel.unassigned) }
                    ForEach(board.assignees, id: \.id) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.inline).labelsHidden()
            } label: {
                DashboardTagLabel(title: assigneeTitle, symbol: "chevron.down", active: !board.assigneeFilter.isEmpty)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityIdentifier("project-board-assignee")
        }
    }

    private var assigneeTitle: String {
        switch board.assigneeFilter {
        case "": String(localized: "All assignees")
        case WebBoardViewModel.unassigned: String(localized: "Unassigned")
        case let id: board.assignees.first { $0.id == id }?.name ?? String(localized: "All assignees")
        }
    }
}
