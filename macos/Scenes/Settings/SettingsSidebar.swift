import AppKit
import SwiftUI

/// The Settings window's section list, drawn as the main window's sidebar is (`CocoaSidebar`): a
/// medium source list of the same rows (`SidebarRowView`, `SidebarCellView`), so a section reads as
/// the Dashboard's row does — its height and type, its icon in the sidebar's grey, and the quiet grey
/// selection whether or not the list has the keyboard. A SwiftUI sidebar list draws the system's own
/// instead: accent-tinted icons, and an accent plate while it has the keyboard.
///
/// The list stands inside the window's backdrop (`WindowBackdropView`), as the main sidebar's does
/// (`MainSidebarController`): the backdrop runs up under the title bar, the list starts below it, and
/// a selection drawn inside the backdrop's material is the main sidebar's shade, not a flat grey.
struct SettingsSidebar: NSViewRepresentable {
    @Binding var selection: SettingsSection
    /// How much of the backdrop's wash is laid on (`WindowBackdrop.opacity`), as on the main sidebar.
    var washOpacity: Double = 1

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> WindowBackdropView {
        let backdrop = WindowBackdropView()
        backdrop.washOpacity = washOpacity
        let list = Self.list(context.coordinator, showing: selection)
        list.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(list)
        backdrop.addSubview(UnifiedToolbar())
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            list.topAnchor.constraint(equalTo: backdrop.safeAreaLayoutGuide.topAnchor),
            list.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
        ])
        return backdrop
    }

    /// The list as the window shows it, built apart from SwiftUI so a test builds the same one.
    static func list(_ coordinator: Coordinator, showing section: SettingsSection) -> NSScrollView {
        let table = NSTableView()
        table.identifier = .init("settings-sidebar")
        table.setAccessibilityIdentifier("settings-sidebar")
        table.setAccessibilityLabel(String(localized: "Settings"))
        SidebarList.configure(table)
        table.allowsEmptySelection = false
        table.dataSource = coordinator
        table.delegate = coordinator
        let scroll = SidebarList.scrollView(table)
        coordinator.table = table
        coordinator.show(section)
        return scroll
    }

    func updateNSView(_ backdrop: WindowBackdropView, context: Context) {
        backdrop.washOpacity = washOpacity
        context.coordinator.selection = $selection
        context.coordinator.show(selection)
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        static let sections = SettingsSection.allCases
        var selection: Binding<SettingsSection>
        weak var table: NSTableView?
        private var updating = false

        init(selection: Binding<SettingsSection>) { self.selection = selection }

        /// Selects the section's row without reporting it back: the model chose it.
        func show(_ section: SettingsSection) {
            guard let table, let row = Self.sections.firstIndex(of: section), table.selectedRow != row else { return }
            updating = true
            defer { updating = false }
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }

        func numberOfRows(in tableView: NSTableView) -> Int { Self.sections.count }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { SidebarMetrics.rowHeight }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = SidebarRowView()
            view.hoverable = Self.sections[row].entry.hoverable
            return view
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("settings-section")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? SidebarCellView ?? {
                let cell = SidebarCellView()
                cell.identifier = identifier
                return cell
            }()
            cell.configure(Self.sections[row].entry, nested: false)
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table, Self.sections.indices.contains(table.selectedRow) else { return }
            selection.wrappedValue = Self.sections[table.selectedRow]
        }
    }
}

/// Gives the Settings window the main window's toolbar style (`MainWindowController`): the sidebar
/// toggle beside the traffic lights and the title over the detail, not a Settings window's taller
/// bar with the toggle on a row of its own. Colour-free and size-free, so nothing finds it.
private final class UnifiedToolbar: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.toolbarStyle = .unified
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension SettingsSection {
    /// The section's row: its symbol and title, set as the main sidebar's Dashboard row is.
    var entry: SidebarEntry {
        SidebarEntry(id: "settings-section-\(self)", title: String(localized: String.LocalizationValue(rawValue)), symbol: symbol)
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .browser: "globe"
        case .terminal: "terminal"
        case .editor: "doc.plaintext"
        case .worktrees: "arrow.triangle.branch"
        case .shortcuts: "keyboard"
        case .remote: "desktopcomputer"
        case .clis: "puzzlepiece.extension"
        case .system: "cpu"
        case .activity: "clock"
        }
    }
}
