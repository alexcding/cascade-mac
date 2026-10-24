import AppKit
import SFSafeSymbols
import SFSymbolsPicker
import SwiftUI

/// A project's icon as the sidebar draws it: its chosen SF Symbol, or the sidebar's folder for
/// `ProjectDraft.defaultIcon`, tinted by the foreground style.
struct ProjectSymbol: View {
    let symbol: String
    let size: CGFloat

    var body: some View {
        if symbol == ProjectDraft.defaultIcon {
            Image(nsImage: SidebarIcons.mark(symbol, size: size) ?? NSImage()).renderingMode(.template)
        } else {
            Image(systemName: symbol).font(.system(size: size - 1))
        }
    }
}

/// The project's icon as a button that opens the SF Symbols picker. A project left alone stores
/// nothing and keeps following the default, as does one whose symbol this macOS does not have;
/// either shows as the sidebar's folder.
struct ProjectIconButton: View {
    @Binding var icon: String
    @State private var picking = false

    var body: some View {
        // Checked once per change of the icon, not on every read of the picker's selection.
        let symbol = Project.symbol(for: icon)
        Button { picking = true } label: {
            ProjectSymbol(symbol: symbol, size: 16).frame(width: 22, height: 18)
        }
        .help(String(localized: "Choose Icon"))
        .accessibilityLabel(String(localized: "Project Icon"))
        .accessibilityIdentifier("project-icon")
        .sheet(isPresented: $picking) {
            ProjectIconPicker(selection: Binding(get: { symbol == ProjectDraft.defaultIcon ? "" : symbol }, set: {
                icon = $0
                picking = false
            }))
        }
    }
}

/// The SF Symbols picker with the system's categories in a sidebar beside it, wide and short so
/// it fits over the forms it opens from. Use Folder goes back to the default.
private struct ProjectIconPicker: View {
    /// The chosen symbol; empty is the default folder.
    @Binding var selection: String
    @State private var category = "all"
    /// Read off the main thread: the system's tables run to thousands of symbols.
    @State private var catalog: SymbolCategories?
    /// The picked category's symbols, made once per category rather than on every redraw.
    @State private var symbols: [SFSymbol] = []

    var body: some View {
        VStack(spacing: 0) {
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
                SymbolsPicker(selection: $selection, title: String(localized: "Project Icon"), symbols: symbols)
                    .id(category)
            }
            Divider()
            HStack {
                Button { selection = "" } label: {
                    Label { Text("Use Folder") } icon: { ProjectSymbol(symbol: ProjectDraft.defaultIcon, size: 14) }
                }
                .disabled(selection.isEmpty)
                .accessibilityIdentifier("project-icon-default")
                Spacer()
            }
            .padding(10)
        }
        .frame(width: 760, height: 460)
        .task { catalog = await Task.detached(priority: .userInitiated) { SymbolCategories.system }.value }
        .onChange(of: category, initial: true) { updateSymbols() }
        .onChange(of: catalog?.categories.count) { updateSymbols() }
    }

    private func updateSymbols() {
        symbols = (catalog?.categories.first { $0.id == category }?.symbols ?? []).map { SFSymbol(rawValue: $0) }
    }
}
