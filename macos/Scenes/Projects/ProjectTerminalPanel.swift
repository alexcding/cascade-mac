import AppKit
import SwiftUI

/// The project's pages over its terminal, split by a divider that drags the terminal's height.
/// With the panel hidden the pages have the whole screen. Showing and hiding slide the panel in
/// from the bottom edge and out again; a drag resizes it at once.
struct ProjectTerminalSplit<Content: View>: View {
    let model: ProjectTerminalViewModel
    @ViewBuilder let content: Content
    /// What the pages keep however tall the terminal is dragged.
    private let minimumContent = 160.0

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if model.shown {
                    let limit = max(ProjectTerminalViewModel.minimumHeight, geometry.size.height - minimumContent)
                    VStack(spacing: 0) {
                        ProjectTerminalDivider(height: min(model.height, limit)) { model.resize(to: min($0, limit)) }
                        ProjectTerminalPanel(model: model)
                            .frame(height: min(model.height, limit))
                            .clipped()
                    }
                    .transition(.move(edge: .bottom))
                }
            }
        }
    }
}

/// A hairline with a taller grip, dragged in the window's coordinates so the moving divider never
/// feeds back into its own drag.
private struct ProjectTerminalDivider: View {
    let height: Double
    let resize: (Double) -> Void
    @State private var start: Double?

    var body: some View {
        Rectangle()
            .fill(Theme.border)
            .frame(height: Theme.Size.hairline)
            .frame(maxWidth: .infinity)
            .overlay {
                Color.clear
                    .frame(height: 8)
                    .contentShape(Rectangle())
                    .modifier(RowResizePointer())
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            let start = start ?? height
                            self.start = start
                            resize(start - value.translation.height)
                        }
                        .onEnded { _ in start = nil })
            }
            .accessibilityHidden(true)
    }
}

/// The terminal and its bar: where it runs, which the bar can change, and Hide.
struct ProjectTerminalPanel: View {
    let model: ProjectTerminalViewModel

    var body: some View {
        VStack(spacing: 0) {
            bar
            Rectangle().fill(Theme.border).frame(height: Theme.Size.hairline)
            if let terminal = model.terminal {
                TerminalPane(session: terminal).id(terminal.id)
            } else if model.pending {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // A shell that could not be made: the bar says why; closing and opening asks again.
                Text("No terminal").foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.background)
        .accessibilityIdentifier("project-terminal")
    }

    private var bar: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal").foregroundStyle(Theme.textSecondary)
            Text("Terminal").font(.callout.weight(.semibold))
            locationMenu
            if let error = model.error {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
                Text(error).font(.callout).foregroundStyle(Theme.textSecondary)
                    .lineLimit(1).truncationMode(.tail).help(error)
                Button(action: model.dismissError) { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                    .accessibilityLabel(String(localized: "Dismiss"))
            }
            Spacer(minLength: 0)
            Button { withAnimation(.projectTerminalSlide) { model.setShown(false) } } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help(String(localized: "Hide Terminal"))
                .accessibilityLabel(String(localized: "Hide Terminal"))
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
    }

    /// Where the shell runs: the project's checkout or one of its worktrees, by branch. Choosing
    /// another starts a shell there; git is never asked to move anything.
    private var locationMenu: some View {
        Menu {
            if model.locations.isEmpty {
                Text(model.loadingLocations ? String(localized: "Loading worktrees…") : String(localized: "No worktrees"))
            }
            ForEach(model.locations) { location in
                Button { model.open(location) } label: {
                    let title = location.isProjectFolder ? String(localized: "\(location.title) — project folder") : location.title
                    if model.isCurrent(location) { Label(title, systemImage: "checkmark") } else { Text(title) }
                }
                .disabled(model.isCurrent(location))
            }
            Divider()
            Button(String(localized: "Refresh Worktrees")) { Task { await model.loadLocations() } }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                Text(model.locationTitle).lineLimit(1).truncationMode(.middle)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.pending)
        .help(model.directory)
        .accessibilityIdentifier("project-terminal-location")
    }
}

extension Animation {
    /// The terminal panel showing and hiding. The toggles that do either animate with it, so
    /// nothing else that changes alongside, a drag least of all, is animated.
    static var projectTerminalSlide: Animation { .easeInOut(duration: 0.22) }
}
