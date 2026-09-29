import AppKit
import SwiftUI

struct GitHistoryView: View {
    @Bindable var model: GitHistoryViewModel
    @FocusState private var finding: Bool
    @State private var showsMessage = false
    var body: some View {
        VStack(spacing: 0) {
            header
            if let error = model.error { Text(error).font(.callout).foregroundStyle(.orange).padding(.horizontal, 12).padding(.bottom, 6) }
            if model.rows.isEmpty {
                // Nothing to list, so nothing to choose: one state for the whole pane.
                empty
            } else {
                // The commits take the top third and the commit's diff the rest.
                VerticalSplit(fraction: 0.3, minTop: 130, minBottom: 160) { list } bottom: { detail }
            }
        }
        .onChange(of: model.findRequest) { _, _ in finding = true }
    }

    /// The search field and Refresh, drawn as the footer's capsules are.
    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textTertiary).accessibilityHidden(true)
                TextField(String(localized: "Search loaded commits"), text: $model.search).textFieldStyle(.plain).focused($finding)
                // An empty pane shows its own spinner.
                if model.loading, !model.rows.isEmpty { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 12)
            .frame(height: Theme.Size.largeControl)
            .background(Theme.surfaceHover, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.border, lineWidth: Theme.Size.hairline))
            HoverCircleButton(String(localized: "Refresh History"), systemImage: "arrow.clockwise", enabled: !model.loading, action: model.refresh)
                .help(String(localized: "Refresh History"))
                .barGlass()
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    @ViewBuilder private var empty: some View {
        if model.loading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 12) {
                Image(systemName: model.search.isEmpty ? "arrow.triangle.branch" : "magnifyingglass")
                    .font(.system(size: 28, weight: .light)).foregroundStyle(Theme.textTertiary).accessibilityHidden(true)
                Text(model.emptyLabel).font(Theme.Typography.emptyTitle).foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                if model.hasMore { loadOlder }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The branch's commits, then — as the list asks for more — the history it grew from.
    private var list: some View {
        List(selection: Binding(get: { model.selectedSHA }, set: model.select)) {
            Section {
                ForEach(model.rows) { commit in
                    HStack(spacing: 10) {
                        Text(commit.initials).font(.caption2.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                            .frame(width: 24, height: 24).background(Theme.surfaceHover, in: Circle()).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(commit.subject).lineLimit(1).fontWeight(.medium)
                            if !commit.refs.isEmpty {
                                Text(commit.refs.map(\.name).joined(separator: " · ")).font(.caption2).foregroundStyle(.tint).lineLimit(1)
                            }
                            Text("\(commit.author) · \(commit.dateLabel) · \(commit.short)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(commit.sha).accessibilityIdentifier("history-commit-\(commit.sha)")
                }
                if model.hasMore {
                    // The last row, so it scrolls with the commits instead of covering them.
                    loadOlder.frame(maxWidth: .infinity).padding(.vertical, 4).listRowSeparator(.hidden).selectionDisabled()
                }
            } header: {
                Text(model.contextLabel)
            }
        }
        .listStyle(.inset)
        .accessibilityIdentifier("git-history-list")
    }

    private var loadOlder: some View {
        // The padded capsule is the label, so all of it takes the click.
        Button(action: model.loadMore) {
            Label(model.loadingMore ? String(localized: "Loading Older Commits…") : String(localized: "Load Older Commits"),
                  systemImage: "clock.arrow.circlepath")
                .padding(.horizontal, 14).frame(maxHeight: .infinity).contentShape(Capsule())
        }
        .barGlass(iconOnly: false)
        .disabled(model.loading || model.loadingMore)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            // This region never changes size: selecting a commit swaps
            // what is in it, and the previous commit stays up until the next one arrives.
            if let error = model.detailError {
                VStack(spacing: 8) {
                    Text(error).foregroundStyle(.orange)
                    Button(String(localized: "Retry Commit"), action: model.retryDetail)
                }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let detail = model.detail {
                // The diff is what this pane is for, so the commit takes two lines: the
                // subject and who/when. A longer message opens on demand.
                let hasBody = detail.meta.message != detail.meta.subject
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if hasBody {
                            Button(showsMessage ? String(localized: "Hide Commit Message") : String(localized: "Show Commit Message"),
                                   systemImage: showsMessage ? "chevron.down" : "chevron.right") { showsMessage.toggle() }
                                .labelStyle(.iconOnly).buttonStyle(.borderless).font(.caption)
                        }
                        Text(detail.meta.subject).fontWeight(.semibold).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 4)
                        if model.loadingDetail { ProgressView().controlSize(.small) }
                        Button(String(localized: "Copy Commit SHA"), systemImage: "doc.on.doc", action: model.copySHA)
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                    Text(detail.meta.authorLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if hasBody, showsMessage {
                        ScrollView { Text(detail.meta.message).font(.callout).frame(maxWidth: .infinity, alignment: .leading) }
                            .frame(maxHeight: 120).padding(.top, 4)
                    }
                }.padding(.horizontal, 12).padding(.vertical, 8).textSelection(.enabled)
                Divider()
                if let patch = model.patch { DiffView(model: patch, showsHeader: false) }
            } else if model.loadingDetail {
                ProgressView(String(localized: "Loading commit…")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(String(localized: "Select a commit"), systemImage: "clock.arrow.circlepath")
            }
        }
    }
}

/// Two panes, one above the other, split by a divider to drag. The top pane starts at `fraction`
/// of the height, where VSplitView always starts at half whatever its panes ask for.
private struct VerticalSplit<Top: View, Bottom: View>: View {
    @State var fraction: CGFloat
    let minTop: CGFloat
    let minBottom: CGFloat
    @ViewBuilder let top: Top
    @ViewBuilder let bottom: Bottom
    /// The top pane's height when the drag began: the divider moves by how far the pointer has,
    /// so a click on it moves nothing.
    @State private var dragStart: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            let total = proxy.size.height
            let current = height(total * fraction, in: total)
            VStack(spacing: 0) {
                top.frame(height: current)
                Divider().overlay {
                    // A thin line, with a handle a few points taller to take the pointer.
                    Color.clear.frame(height: 7).contentShape(Rectangle())
                        .modifier(RowResizePointer())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                            let start = dragStart ?? current
                            dragStart = start
                            if total > 0 { fraction = height(start + drag.translation.height, in: total) / total }
                        }.onEnded { _ in dragStart = nil })
                }
                bottom.frame(maxHeight: .infinity)
            }
        }
    }

    private func height(_ proposed: CGFloat, in total: CGFloat) -> CGFloat {
        // Too short for both panes' least heights: share it rather than push the bottom one out.
        guard total >= minTop + minBottom else { return max(0, min(proposed, total)) }
        return max(minTop, min(proposed, total - minBottom))
    }
}

/// The up-and-down resize pointer over a divider. Before macOS 15 it is pushed on entry and popped
/// on exit, and popped too if the view goes while the pointer is over it, so none is left behind.
private struct RowResizePointer: ViewModifier {
    @State private var pushed = false

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.pointerStyle(.rowResize)
        } else {
            content
                .onHover { inside in
                    if inside, !pushed { NSCursor.resizeUpDown.push(); pushed = true }
                    else if !inside, pushed { NSCursor.pop(); pushed = false }
                }
                .onDisappear { if pushed { NSCursor.pop(); pushed = false } }
        }
    }
}
