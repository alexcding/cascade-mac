import AppKit
import SFSafeSymbols
import SFSymbolsPicker
import SwiftUI

/// The project's icon as a button that opens the SF Symbols picker. Choosing the folder stores
/// nothing, so a project left alone keeps following the default; a symbol this macOS does not
/// have shows as the folder, as the sidebar draws it.
struct ProjectIconButton: View {
    @Binding var icon: String
    @State private var picking = false

    private var symbol: String {
        icon.isEmpty || NSImage(systemSymbolName: icon, accessibilityDescription: nil) == nil ? ProjectDraft.defaultIcon : icon
    }

    var body: some View {
        Button { picking = true } label: {
            Image(systemName: symbol).font(.system(size: 15)).frame(width: 22, height: 18)
        }
        .help(String(localized: "Choose Icon"))
        .accessibilityLabel(String(localized: "Project Icon"))
        .accessibilityIdentifier("project-icon")
        .sheet(isPresented: $picking) {
            ProjectIconPicker(selection: Binding(get: { symbol }, set: {
                icon = $0 == ProjectDraft.defaultIcon ? "" : $0
                picking = false
            }))
        }
    }
}

/// The SF Symbols picker with the system's categories in a sidebar beside it, wide and short so
/// it fits over the forms it opens from.
private struct ProjectIconPicker: View {
    @Binding var selection: String
    @State private var category = "all"
    /// Read off the main thread: the system's tables run to thousands of symbols.
    @State private var catalog: SymbolCategories?

    var body: some View {
        HStack(spacing: 0) {
            if let categories = catalog?.categories, !categories.isEmpty {
                List(categories, selection: $category) { item in
                    Label(item.title, systemImage: item.icon).tag(item.id)
                }
                .listStyle(.sidebar)
                .frame(width: 200)
                .accessibilityIdentifier("project-icon-categories")
                Divider()
            }
            // The picker keeps the symbols it was made with, so a new category makes a new picker.
            // The picker's own autoDismiss waits for the selection to change, so the symbol
            // already chosen would leave it open; a tap writes the binding either way.
            SymbolsPicker(selection: $selection, title: String(localized: "Project Icon"),
                          symbols: symbols.map { SFSymbol(rawValue: $0) })
                .id(category)
        }
        .frame(width: 760, height: 420)
        .task { catalog = await Task.detached(priority: .userInitiated) { SymbolCategories.system }.value }
    }

    private var symbols: [String] {
        catalog?.categories.first { $0.id == category }?.symbols ?? []
    }
}
