import AppKit
import SwiftUI
import WebKit

private struct FallbackToolbarIcon: View {
    enum Kind { case code, split, branch }
    let kind: Kind

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 24
            context.scaleBy(x: scale, y: scale)
            var path = Path()
            switch kind {
            case .code:
                path.move(to: .init(x: 9, y: 17)); path.addLine(to: .init(x: 4, y: 12)); path.addLine(to: .init(x: 9, y: 7))
                path.move(to: .init(x: 15, y: 7)); path.addLine(to: .init(x: 20, y: 12)); path.addLine(to: .init(x: 15, y: 17))
            case .split:
                path.addRoundedRect(in: .init(x: 3, y: 4.5, width: 18, height: 15), cornerSize: .init(width: 3.5, height: 3.5))
                path.move(to: .init(x: 14, y: 4.5)); path.addLine(to: .init(x: 14, y: 19.5))
            case .branch:
                path.move(to: .init(x: 6, y: 3)); path.addLine(to: .init(x: 6, y: 15))
                path.addEllipse(in: .init(x: 15, y: 3, width: 6, height: 6))
                path.addEllipse(in: .init(x: 3, y: 15, width: 6, height: 6))
                path.move(to: .init(x: 18, y: 9)); path.addCurve(to: .init(x: 9, y: 18), control1: .init(x: 18, y: 13.97), control2: .init(x: 13.97, y: 18))
            }
            context.stroke(path, with: .foreground, style: .init(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 18, height: 18)
    }
}

/// Xcode's own activity-view tile: it draws a hammer symbol on a blue rounded square with an
/// inset hairline, not a bitmap, so this is the same composition from the public symbol. The
/// tile takes the theme's accent; the white is the artwork's own ink, as in the bundled brand PNGs.
private struct XcodeBuildIcon: View {
    let side: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: side * 0.23, style: .continuous)
        shape.fill(Theme.accent)
            .overlay { shape.inset(by: side * 0.1).strokeBorder(.white.opacity(0.55), lineWidth: max(1, side * 0.045)) }
            .overlay { Image(systemName: "hammer.fill").font(.system(size: side * 0.5, weight: .medium)).foregroundStyle(.white) }
            .frame(width: side, height: side)
    }
}

private struct ToolbarBrandIcon: View {
    let name: String?
    let fallback: FallbackToolbarIcon.Kind
    var height: CGFloat = 18

    var body: some View {
        if name == "xcode" {
            XcodeBuildIcon(side: height)
        } else if let name, let image = Self.load(name) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(height: height)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            FallbackToolbarIcon(kind: fallback)
        }
    }

    private static func load(_ name: String) -> NSImage? {
        let filename = "\(name).png"
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/CascadeImages")
            .appendingPathComponent(filename)
        if let image = NSImage(contentsOf: bundled) { return image }

        // Xcode development builds do not run the packaging script, so resolve the
        // same committed artwork from the checkout while iterating.
        var directory = URL(fileURLWithPath: #filePath)
        for _ in 0..<8 {
            directory.deleteLastPathComponent()
            let candidate = directory.appendingPathComponent("macos/Resources/ProviderImages")
                .appendingPathComponent(filename)
            if let image = NSImage(contentsOf: candidate) { return image }
        }
        return nil
    }
}

struct BrowserSurface: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}

/// Every loaded page of a panel stays in the window, and switching tabs only changes which one
/// is hidden. A web view that leaves the window drops its painted layers and comes back blank
/// until the page draws again, which is a flash on every tab switch.
struct BrowserSurfaceStack: NSViewRepresentable {
    let webViews: [WKWebView]
    let active: WKWebView?

    func makeNSView(context: Context) -> BrowserSurfaceHost { BrowserSurfaceHost() }
    func updateNSView(_ host: BrowserSurfaceHost, context: Context) { host.show(active, among: webViews) }
}

final class BrowserSurfaceHost: NSView {
    func show(_ active: WKWebView?, among webViews: [WKWebView]) {
        for stale in subviews where !webViews.contains(where: { $0 === stale }) { stale.removeFromSuperview() }
        // Only a view nobody holds, or one a previous host of this panel left behind: WebKit moves
        // a page into its own window for element fullscreen, and it must be left there.
        for view in webViews where view.superview == nil || (view.superview !== self && view.superview is BrowserSurfaceHost) {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
        let focused = window?.firstResponder as? NSView
        let handsOn = webViews.contains { view in view !== active && focused?.isDescendant(of: view) == true }
        for view in webViews { view.isHidden = view !== active }
        // Hiding a view does not take the keyboard from it: hand it on, or keys reach a page
        // nobody can see.
        if handsOn { window?.makeFirstResponder(active) }
    }
}

struct BrowserPane: View {
    let page: BrowserPage
    let context: WorkspaceContext
    let model: BrowserControlsViewModel
    let workspace: SessionWorkspaceViewModel
    @FocusState private var finding: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Navigation and the address live in the compact tab bar above this pane.
            if context.findVisible {
                HStack {
                    TextField(String(localized: "Find in page"), text: Binding(get: { context.findText }, set: { context.findText = $0 }))
                        .capsuleField()
                        .focused($finding).onSubmit { model.find(context.findText) }
                    if model.found == false { Text(String(localized: "No match")).font(.caption).foregroundStyle(.secondary) }
                    Button(String(localized: "Previous Match"), systemImage: "chevron.up") { model.find(context.findText, backwards: true) }
                    Button(String(localized: "Next Match"), systemImage: "chevron.down") { model.find(context.findText) }
                    Button(String(localized: "Close Find"), systemImage: "xmark") { context.findVisible = false }
                }.glassIconButtons().padding(8)
            }
            if let error = model.error {
                HStack { Text(error).font(.callout); Spacer(); Button(String(localized: "Retry"), action: model.retry) }
                    .padding(10).foregroundStyle(.orange)
            }
            ForEach(page.downloads) { download in
                BrowserDownloadRow(download: download) { page.dismiss(download) }
            }
            ZStack {
                BrowserSurfaceStack(webViews: context.pages.compactMap(\.webView), active: model.isBlank ? nil : page.webView)
                    .accessibilityHidden(page.dialogs.request != nil)
                if model.isBlank {
                    // Safari's start page: a blank tab shows where this panel has been.
                    // Per tab: what one blank tab expanded or searched is not the next one's.
                    BrowserStartPage(context: context, controls: model, worktree: workspace.session?.worktree,
                                     reopenFile: { workspace.reopen(.file($0)) }, tools: workspace.startPageTools()).id(page.id)
                } else if page.webView == nil {
                    ContentUnavailableView(String(localized: "Page suspended"), systemImage: "globe", description: Text(String(localized: "Select this tab to reload it.")))
                }
            }
        }
        .onAppear { model.synchronizeAddress() }
        .onChange(of: page.id) { model.synchronizeAddress() }
        .onChange(of: context.findVisible) { _, value in if value { finding = true } }
        .onExitCommand { context.findVisible = false }
    }
}

/// One saved file under the address: a bar while it transfers, then where it went.
private struct BrowserDownloadRow: View {
    let download: BrowserDownload
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: download.error != nil ? "exclamationmark.circle" : download.finished ? "checkmark.circle" : "arrow.down.circle")
                .foregroundStyle(download.error != nil ? Theme.danger : Theme.textSecondary)
            Text(download.filename).font(.callout).lineLimit(1).truncationMode(.middle)
            if let error = download.error { Text(error).font(.caption).foregroundStyle(Theme.danger).lineLimit(1) }
            else if download.running { ProgressView(value: download.fraction).frame(maxWidth: 160) }
            Spacer()
            if download.finished { Button(String(localized: "Show in Finder"), action: download.reveal) }
            Button(download.running ? String(localized: "Cancel Download") : String(localized: "Dismiss"), systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("browser-download")
    }
}

struct SessionWorkspaceView: View {
    let context: WorkspaceContext
    let model: SessionWorkspaceViewModel

    var body: some View {
        VStack(spacing: 0) {
            if let error = context.error { Text(error).font(.caption).foregroundStyle(.orange).padding(8) }
            if let error = model.launchError {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled).padding(8)
                    .accessibilityIdentifier("workspace-launch-error")
            }
            primaryContent
        }
    }

    /// Beside a terminal, the context pane is not drawn here: it is the window's inspector column
    /// (`SessionWorkspacePane`), presented by the app for the workspace on screen.
    @ViewBuilder private var primaryContent: some View {
        if model.showsTerminal {
            terminalContent
        } else {
            VStack(spacing: 0) {
                Divider()
                SessionWorkspaceContextContent(context: context, model: model)
            }
        }
    }

    @ViewBuilder private var terminalContent: some View {
        if let terminal = model.terminal {
            TerminalPane(session: terminal).id(terminal.id)
                .allowsHitTesting(!model.chatCoversTerminal)
                .overlay(alignment: .top) {
                    if model.showsChat, let chat = model.chat {
                        TranscriptChatOverlay(chat: chat, busy: terminal.agentBusy, idle: terminal.agentTurns.idle,
                                              asking: terminal.agentTurns.mayBeAsking,
                                              startedAt: terminal.agentStartedAt, active: model.isActive,
                                              placeholder: model.session?.agent.chatPlaceholder ?? "")
                    }
                }
                .task(id: terminal.id) { model.restoreChatMode() }
        } else if model.removingSession {
            ProgressView(String(localized: "Removing Session…"))
        } else if model.session != nil {
            ProgressView(String(localized: "Opening Terminal…"))
        } else {
            VStack(spacing: 12) {
                Text(model.terminalPrompt).foregroundStyle(.secondary)
                Button(String(localized: "Open Terminal"), systemImage: "terminal", action: model.openTerminal).buttonStyle(.borderedProminent)
            }
        }
    }

}

private struct SessionWorkspaceContextContent: View {
    let context: WorkspaceContext
    let model: SessionWorkspaceViewModel

    var body: some View {
        VStack(spacing: 0) {
            if model.shownPane == .term {
                // Safari's compact layout: the tab bar is the address bar, so the browser needs no second row.
                BrowserCompactTabBar(context: context, model: model)
                Divider()
            }
            SessionWorkspaceContextBody(context: context, model: model)
        }
    }
}

/// What the context pane shows under its bars: the tab strip, and the address or review row.
struct SessionWorkspaceContextBody: View {
    let context: WorkspaceContext
    let model: SessionWorkspaceViewModel

    @ViewBuilder var body: some View {
        if model.showsChanges {
            // The review row above carries the Changes/History switch and the commit action; the diff
            // fills the pane.
            Group {
                if context.reviewSection == .history, let history = model.history { GitHistoryView(model: history) }
                else if context.reviewSection == .changes, let diff = model.diff {
                    // The changed files to the right of the diff, split as the editor's tree is
                    // (`WorkspaceFileBrowser`); choosing one scrolls the diff to it.
                    if diff.filesShown {
                        ThinSplitView(leading: .init(min: 200), trailing: .init(min: 120, ideal: 240, max: 400)) {
                            DiffView(model: diff, showsHeader: false)
                        } trailingContent: {
                            DiffChangedFiles(diff: diff)
                        }
                    } else {
                        DiffView(model: diff, showsHeader: false)
                    }
                }
                else { Color.clear }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.shownPane == .term, let document = context.activeDocument {
            WorkspaceFileBrowser(context: context, model: model, document: document)
        } else if model.shownPane == .term, let page = context.activePage {
            // Not keyed by page: a new identity would rebuild the surface and re-parent the web views.
            BrowserPane(page: page, context: context, model: page.controls, workspace: model)
        } else if model.shownPane == .simulator, let preview = model.simulatorPreview {
            SimulatorPanelView(model: preview, openIntegrations: model.openHookSettings)
        } else if context.activeTool == .files {
            WorkspaceFileBrowser(context: context, model: model, document: nil)
        } else if context.activeTool == .live {
            Group {
                if let live = model.live { LivePanelView(live: live, workspace: model) }
                else if !model.canShowLive {
                    ContentUnavailableView(String(localized: "No agent"), systemImage: WorkspaceTool.live.symbol,
                                           description: Text(String(localized: "This session runs no agent to show.")))
                } else { Color.clear }
            }
            .task(id: model.canShowLive) { model.prepareLive() }
        } else {
            BlankPane(context: context, model: model)
        }
    }
}

/// The review's controls, all leading: the Changes/History switch, Commit and the changed files'
/// toggle, in a row under the pane's tab strip while Diff's tab is shown (`SessionWorkspacePane`).
struct ReviewBar: View {
    let context: WorkspaceContext
    let diff: DiffViewModel?

    var body: some View {
        HStack(spacing: 10) {
            SegmentedPicker(title: String(localized: "Review section"), options: ReviewSection.allCases, label: \.title,
                                 selection: Binding(get: { context.reviewSection }, set: context.setReviewSection))
            // Everything leading, beside Changes/History; the slack after it. The same buttons over
            // History, so switching moves nothing: Commit still commits the working changes, and the
            // changed files' toggle waits.
            if let diff {
                let busy = diff.showsProgress
                // Commit and the changed files' toggle in one capsule, as Run and Stop are.
                ButtonGroup {
                    if let actions = diff.actions {
                        Button(action: diff.requestActions) {
                            Label(String(localized: "Commit…"), systemImage: "checkmark.circle")
                                .labelStyle(.titleAndIcon)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 10)
                                .frame(maxHeight: .infinity)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(actions.busy)
                        .opacity(actions.busy ? 0.5 : 1)
                        .commitPopover(diff)
                        Divider().frame(height: 16)
                    }
                    FileTreeToggle(shown: Binding(get: { diff.filesShown }, set: { diff.filesShown = $0 }),
                                   enabled: context.reviewSection == .changes)
                }
                if busy { ProgressView().controlSize(.small) }
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .accessibilityIdentifier("workspace-review-bar")
    }
}

/// The changed files beside the diff, reading them in its own body: a split's pane is updated
/// when the split is, not when the diff's files change.
private struct DiffChangedFiles: View {
    let diff: DiffViewModel
    var body: some View { ChangedFilesView(files: diff.changedFiles, reveal: diff.reveal) }
}

/// The right pane with nothing in it: a real surface that names what
/// the pane is for, not a void. It gives the open/close animation something to resize.
struct BlankPane: View {
    let context: WorkspaceContext
    let model: SessionWorkspaceViewModel

    var body: some View {
        VStack(spacing: 5) {
            Text(String(localized: "Nothing open in this panel"))
                .font(Theme.Typography.emptyTitle)
                .foregroundStyle(Theme.textSecondary)
            Text(String(localized: "Use ＋ to open a web page or search this worktree's files."))
                .font(Theme.Typography.emptyHint).foregroundStyle(Theme.textTertiary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: 260)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Under the pane's bar, not behind it: a background into the top safe area hides its tabs.
        .paneSurface(ignoresSafeAreaEdges: [])
    }
}

/// The project's IDE icon ahead of the session title; opens the worktree in that editor.
struct SessionWorkspaceEditorButton: View {
    let model: SessionWorkspaceViewModel
    var height: CGFloat = 18

    var body: some View {
        if let title = model.editorLabel {
            Button(action: model.openEditor) {
                ToolbarBrandIcon(name: model.editorID, fallback: .code, height: height)
            }
            .buttonStyle(.plain)
            .help(title)
            .disabled(!model.canOpenExternal)
        }
    }
}

/// Xcode's Run | Stop pair in one capsule, ahead of the IDE tile. Both are always there: Run
/// greys out while a build is going, Stop while none is.
struct SessionWorkspaceRunButton: View {
    let model: SessionWorkspaceViewModel

    var body: some View {
        let running = model.build?.running == true
        // A direct run has no sheet, so the button is what shows it has started.
        let starting = model.build?.starting == true
        // The stock navigation style is what draws one capsule with the system's divider; the
        // automatic style splits the pair into two glass circles.
        ControlGroup {
            Button(String(localized: "Run \(model.runScheme)"), systemImage: "play.fill", action: model.run)
                .help(String(localized: "Build and run \(model.runScheme)"))
                .disabled(running || starting || !model.canRun)
            Button(String(localized: "Stop"), systemImage: "stop.fill") { Task { await model.stopBuild() } }
                .help(String(localized: "Stop the build"))
                .disabled(!running)
        }
        .controlGroupStyle(.navigation)
        .labelStyle(.iconOnly)
    }
}

/// Xcode's activity view for a buildable session: the IDE tile beside the scheme over the
/// session title. The text is one button that opens the current build settings.
struct SessionWorkspaceBuildTitle: View {
    let model: SessionWorkspaceViewModel
    @Environment(ToolbarRoom.self) private var room: ToolbarRoom?

    var body: some View {
        HStack(spacing: 8) {
            SessionWorkspaceEditorButton(model: model, height: 22)
            Button(action: model.configureRun) {
                // Measured as wide as the scheme and no wider, so a long session title neither moves
                // the agent's controls nor widens the button. The line itself is drawn over its
                // place, running on into the free toolbar after the title and not clickable there.
                SchemeWidthStack {
                    HStack(spacing: 4) {
                        Text(model.runScheme).font(.headline).lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: 320, alignment: .leading)
                    // The line's height, held by text that draws nothing: the line itself may animate.
                    Text(verbatim: " ").font(.subheadline).lineLimit(1).hidden()
                }
                .contentShape(Rectangle())
                .overlay {
                    GeometryReader { proxy in
                        subtitle
                            .frame(width: proxy.size.width + overhang, alignment: .leading)
                            .frame(height: proxy.size.height, alignment: .bottom)
                    }
                    .allowsHitTesting(false)
                }
            }
            .buttonStyle(.plain)
            // The line is drawn where the pointer never reaches it, so its explanation is the button's.
            .help(model.warmup.running || model.warmup.failed
                ? SessionWorkspaceWarmupLine.help(model.warmup)
                : String(localized: "Show the build settings: scheme and simulator"))
            .disabled(!model.canRun)
            SessionWorkspaceBuildLogButton(model: model)
        }
        .padding(.leading, 8)
    }

    /// While the worktree is being prepared, that is the more useful subtitle: the session's name
    /// is in the sidebar, the reason Run is slow is not.
    @ViewBuilder private var subtitle: some View {
        if model.warmup.running || model.warmup.failed {
            SessionWorkspaceWarmupLine(state: model.warmup)
        } else {
            Text(model.title).font(.subheadline).foregroundStyle(Theme.textSecondary)
                .lineLimit(1).truncationMode(.tail)
        }
    }

    /// The free toolbar past the title; none while the log button stands beside the text, since the
    /// line would run under it.
    private var overhang: CGFloat {
        SessionWorkspaceBuildLogButton.shows(model) ? 0 : room?.afterLeading ?? 0
    }
}

/// A leading-aligned column as wide as its first view: every line under it is offered that
/// width alone, and truncates to it.
private struct SchemeWidthStack: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let first = subviews.first else { return .zero }
        let top = first.sizeThatFits(proposal)
        let below = subviews.dropFirst().map { $0.sizeThatFits(ProposedViewSize(width: top.width, height: nil)).height }
        return CGSize(width: top.width, height: top.height + below.reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: size.height))
            y += size.height
        }
    }
}

/// The worktree's IDE preparation, in the line the session title usually holds. A fresh
/// checkout resolves its package graph before anything can build, and a build that waits on it
/// silently reads as a hang; the glyph turns for as long as the work is real.
private struct SessionWorkspaceWarmupLine: View {
    let state: IDEWarmupState
    private static let turn: TimeInterval = 1.1

    var body: some View {
        HStack(spacing: 4) {
            // The angle is read off the clock rather than animated in: an implicit
            // `repeatForever` animation on a view whose frame is still settling animates the
            // position too, and the glyph drifts across the toolbar instead of turning in place.
            TimelineView(.animation(paused: !state.running)) { context in
                Image(systemName: state.failed ? "exclamationmark.triangle.fill" : "arrow.triangle.2.circlepath")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(state.failed ? Theme.danger : Theme.accent)
                    .rotationEffect(.degrees(state.running ? Self.angle(at: context.date) : 0))
            }
            .frame(width: 12, height: 12)
            Text(state.failed ? String(localized: "\(state.displayLabel) failed") : String(localized: "\(state.displayLabel)…"))
                .font(.subheadline).foregroundStyle(Theme.textSecondary)
                .lineLimit(1).truncationMode(.tail)
        }
    }

    static func help(_ state: IDEWarmupState) -> String {
        state.failed ? state.message : String(localized: "\(state.displayLabel) in this worktree, so the first build does not wait on it")
    }

    private static func angle(at date: Date) -> Double {
        date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: turn) / turn * 360
    }
}

/// A build never takes a pane, so this is the way to its log: a spinner while it runs, a log
/// glyph once it has ended, since that is where a failure is read. The log is a popover.
private struct SessionWorkspaceBuildLogButton: View {
    let model: SessionWorkspaceViewModel
    @State private var presented = false

    /// Once the app is launched the build is over; it still holds the terminal, so Stop stays.
    static func busy(_ model: SessionWorkspaceViewModel) -> Bool {
        model.build?.starting == true || (model.build?.running == true && model.build?.launched != true)
    }

    static func shows(_ model: SessionWorkspaceViewModel) -> Bool { busy(model) || model.buildTerminal != nil }

    var body: some View {
        let busy = Self.busy(model)
        if Self.shows(model) {
            Button { presented.toggle() } label: {
                Group {
                    if busy { ProgressView().controlSize(.small) }
                    else { Image(systemName: "text.alignleft").foregroundStyle(Theme.textSecondary) }
                }
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "Show the build log"))
            // Not while a build is starting: the viewer and the build would both find no shell and
            // each create one.
            .disabled(model.buildTerminal == nil || model.build?.starting == true)
            .accessibilityIdentifier("build-log")
            .popover(isPresented: $presented, arrowEdge: .bottom) {
                if let build = model.buildTerminal {
                    TerminalPane(session: build).id(build.id)
                        .frame(width: BuildLog.size.width, height: BuildLog.size.height)
                }
            }
        }
    }
}

