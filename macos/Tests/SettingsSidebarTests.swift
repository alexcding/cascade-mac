import AppKit
import SwiftUI
import Testing

/// The Settings window's sections are the main sidebar's own rows: its row height, its icon grey and
/// its quiet selection. The list shows the section the model chose without reporting it back, and a
/// row picked in the list is the model's section.
@MainActor @Test func settingsSectionsAreTheMainSidebarsRows() throws {
    _ = NSApplication.shared
    var section = SettingsSection.general
    var reported = 0
    let coordinator = SettingsSidebar.Coordinator(selection: Binding(get: { section }, set: { section = $0; reported += 1 }))
    let scroll = SettingsSidebar.list(coordinator, showing: .editor)
    scroll.frame = NSRect(x: 0, y: 0, width: 220, height: 400)
    let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = scroll
    window.layoutIfNeeded()
    let table = try #require(coordinator.table)
    let sections = SettingsSection.allCases
    #expect(table.numberOfRows == sections.count)
    #expect(table.selectedRow == sections.firstIndex(of: .editor))
    #expect(reported == 0, "the model's own choice is not reported back to it")

    // The main sidebar's own row, which keeps the selection its grey plate.
    _ = try #require(table.rowView(atRow: 0, makeIfNecessary: true) as? SidebarRowView)
    #expect(!table.allowsTypeSelect, "a typed letter does not jump to a row, as in the main sidebar")
    #expect(table.rect(ofRow: 0).height == SidebarMetrics.rowHeight)
    let cell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? SidebarCellView)
    #expect(cell.icon.contentTintColor == SidebarPalette.icon)
    let title = try #require(cell.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == SettingsSection.general.entry.title })
    #expect(title.font == .systemFont(ofSize: NSFont.systemFontSize))

    table.selectRowIndexes(IndexSet(integer: try #require(sections.firstIndex(of: .clis))), byExtendingSelection: false)
    #expect(section == .clis)
    coordinator.show(.system)
    #expect(table.selectedRow == sections.firstIndex(of: .system))
    #expect(section == .clis, "a section shown from the model is not reported back")
    window.close()
}
