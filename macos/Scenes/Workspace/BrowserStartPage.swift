import SwiftUI

/// What a blank tab shows in place of a web view: the bookmarks as icon tiles, then the newest
/// pages visited in any panel as a list, as many as fit without scrolling. There is one history,
/// shared by every panel. Clicking either loads it in this tab.
struct BrowserStartPage: View {
    let context: WorkspaceContext
    let controls: BrowserControlsViewModel
    /// The full-history screen replaces the start page in this tab until Back is pressed.
    @State private var showingAll = false
    /// Bookmarks fold to `bookmarkRows` rows of however many tiles the pane's width fits.
    @State private var bookmarkColumns = 6
    @State private var showingAllBookmarks = false
    /// The pane's height and where the history rows start in the page, which together say
    /// how many rows fit without scrolling.
    @State private var viewportHeight: CGFloat = 0
    @State private var historyTop: CGFloat = 0

    static let bookmarkRows = 2
    static let tileMinimum: CGFloat = 92, tileSpacing: CGFloat = 8
    static let pagePadding: CGFloat = 24, rowSpacing: CGFloat = 2

    /// How many pages the start page shows before deferring to the full history: as many
    /// rows as fit below the bookmarks, and a few even when none do.
    private var historyLimit: Int {
        let room = viewportHeight - historyTop - Self.pagePadding + Self.rowSpacing
        return min(max(3, Int(room / (StartPageRow.height + Self.rowSpacing))), 30)
    }

    /// One history for the whole app: the newest pages visited in any panel, without the
    /// bookmarked ones, so nothing appears twice on the page.
    private func recent(excluding bookmarks: [BrowserBookmark]) -> [BrowserHistoryEntry] {
        context.globalHistory?.recent(excluding: Set(bookmarks.map(\.url)), limit: historyLimit) ?? []
    }

    var body: some View {
        Group {
            if showingAll, let history = context.globalHistory {
                BrowserHistoryScreen(history: history, back: { showingAll = false }, open: open)
            } else {
                startPage
            }
        }
        .background(Theme.paneBackground)
    }

    private var startPage: some View {
        let bookmarks = context.bookmarks?.bookmarks ?? [], recent = recent(excluding: bookmarks)
        return ScrollView {
            if recent.isEmpty && bookmarks.isEmpty {
                VStack(spacing: 5) {
                    Text("No bookmarks or history yet").font(Theme.Typography.emptyTitle).foregroundStyle(Theme.textSecondary)
                    Text("Pages you bookmark or visit appear here.").font(Theme.Typography.emptyHint).foregroundStyle(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity).padding(.top, 80)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    if !bookmarks.isEmpty {
                        let folded = bookmarkColumns * Self.bookmarkRows
                        HStack {
                            Text("Bookmarks").font(.title3.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                            Spacer()
                            if bookmarks.count > folded {
                                Button(showingAllBookmarks ? "Show Less" : "Show More") { showingAllBookmarks.toggle() }
                                    .buttonStyle(.link)
                                    .accessibilityIdentifier("toggle-all-bookmarks")
                            }
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.tileMinimum, maximum: 112), spacing: Self.tileSpacing, alignment: .top)], spacing: 12) {
                            ForEach(showingAllBookmarks ? bookmarks : Array(bookmarks.prefix(folded))) { bookmark in
                                StartPageTile(record: WebPageRecord(id: bookmark.url, url: bookmark.url, title: bookmark.title),
                                              open: { open(bookmark.url) }, remove: { context.bookmarks?.remove(url: bookmark.url) })
                            }
                        }
                        .onGeometryChange(for: Int.self) { proxy in
                            max(1, Int((proxy.size.width + Self.tileSpacing) / (Self.tileMinimum + Self.tileSpacing)))
                        } action: { bookmarkColumns = $0 }
                        .accessibilityLabel("Bookmarks")
                    }
                    if context.globalHistory?.entries.isEmpty == false {
                        Button { showingAll = true } label: {
                            HStack(spacing: 6) {
                                Text("History").font(.title3.weight(.semibold))
                                Image(systemName: "chevron.right").font(.body.weight(.semibold))
                            }
                            .foregroundStyle(Theme.textSecondary)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, bookmarks.isEmpty ? 0 : 16)
                        .help("Show All History")
                        .accessibilityLabel("Show All History")
                        .accessibilityIdentifier("show-all-history")
                        // Every visited page may be bookmarked: the heading still leads to the full history.
                        if !recent.isEmpty {
                            LazyVStack(alignment: .leading, spacing: Self.rowSpacing) {
                                ForEach(recent) { entry in
                                    StartPageRow(entry: entry) { open(entry.url) }
                                }
                            }
                            .accessibilityLabel("History")
                            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("startPage")).minY } action: { historyTop = $0 }
                        }
                    }
                }
                .padding(Self.pagePadding)
                .coordinateSpace(name: "startPage")
                .readableColumn()
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
    }

    private func open(_ url: String) {
        // Not typed: end editing first, or the address bar treats the URL as text to suggest for.
        controls.setEditingAddress(false)
        controls.address = url
        controls.submitAddress()
    }
}

/// Every page visited in any panel, newest first, with a search field that filters by title
/// or address. Reached from the start page's History heading.
private struct BrowserHistoryScreen: View {
    let history: BrowserHistoryStore
    let back: () -> Void
    let open: (String) -> Void
    @State private var query = ""
    @FocusState private var searching: Bool
    @State private var backHovering = false
    @State private var confirmingClear = false

    private var entries: [BrowserHistoryEntry] {
        query.trimmingCharacters(in: .whitespaces).isEmpty ? history.entries : history.matching(query, limit: Int.max)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button(action: back) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left").font(.body.weight(.semibold))
                        Text("History").font(.title3.weight(.semibold))
                    }
                    .foregroundStyle(backHovering ? Color.primary : Theme.textSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { backHovering = $0 }
                .help("Back to the start page")
                .accessibilityLabel("Back to start page")
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.textTertiary)
                    TextField("Search history", text: $query).textFieldStyle(.plain).focused($searching)
                        .accessibilityIdentifier("history-search")
                    if !query.isEmpty {
                        Button("Clear", systemImage: "xmark.circle.fill") { query = "" }
                            .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: 280).frame(height: Theme.Size.largeControl)
                .background(Theme.surfaceHover, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.border, lineWidth: Theme.Size.hairline))
                Button("Clear History") { confirmingClear = true }
                    .controlSize(.large)
                    .disabled(history.entries.isEmpty)
                    .accessibilityIdentifier("clear-history")
                    .confirmationDialog("Clear all browsing history?", isPresented: $confirmingClear, titleVisibility: .visible) {
                        Button("Clear History", role: .destructive) { history.clear() }
                    } message: {
                        Text("Every page visited in any panel is forgotten. Open tabs stay open.")
                    }
            }
            if entries.isEmpty {
                Text(query.isEmpty ? "No history yet" : "No pages match \u{201C}\(query)\u{201D}")
                    .font(Theme.Typography.emptyTitle).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity).padding(.top, 60)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(entries) { entry in
                            StartPageRow(entry: entry, open: { open(entry.url) }, remove: { history.remove(url: entry.url) })
                        }
                    }
                    .accessibilityLabel("All history")
                }
            }
        }
        .padding(24)
        .readableColumn()
        .onAppear { searching = true }
    }
}

/// One line of the history list: favicon, title, host and when it was last visited.
private struct StartPageRow: View {
    let entry: BrowserHistoryEntry
    let open: () -> Void
    /// Forgets this page. Only the full-history screen offers it; the start page list does not.
    var remove: (() -> Void)? = nil
    @State private var hovering = false

    /// A 24pt favicon inside the row's vertical padding; the start page counts rows by it.
    static let height: CGFloat = 44

    private var visited: String? {
        guard entry.visited > .distantPast else { return nil }
        return entry.visited.formatted(.relative(presentation: .named))
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                FaviconImage(url: entry.url, size: 24)
                Text(entry.displayTitle).font(.body).lineLimit(1)
                Text(entry.host).font(.body).foregroundStyle(Theme.textTertiary).lineLimit(1)
                Spacer(minLength: 8)
                if let visited {
                    Text(visited).font(.callout).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                if let remove {
                    Button("Delete", systemImage: "xmark.circle.fill", action: remove)
                        .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(Theme.textTertiary)
                        .opacity(hovering ? 1 : 0)
                        .help("Remove from history")
                        .accessibilityLabel("Remove \(entry.displayTitle) from history")
                }
            }
            .padding(.horizontal, 12).frame(height: Self.height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Theme.surfaceHover : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(entry.url)
        .contextMenu {
            if let remove { Button("Remove from History", action: remove) }
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct StartPageTile: View {
    let record: WebPageRecord
    let open: () -> Void
    /// Set for a bookmark tile, which can be removed from its context menu.
    var remove: (() -> Void)?
    @State private var hovering = false

    private var store: FaviconStore { .shared }

    private var host: String { URL(string: record.url)?.host ?? record.url }

    /// A touch icon is artwork made for a tile; a small favicon sits centred on the tile instead.
    private static func isTileArtwork(_ image: NSImage) -> Bool {
        (image.representations.map(\.pixelsWide).max() ?? 0) >= 96
    }

    @MainActor private static let bleeds = NSCache<NSImage, NSNumber>()

    /// Whether the artwork is opaque out to every edge of a square. A circle, a wide logo or a
    /// pre-rounded icon is not, and gets a margin instead of being cut by the tile's corners.
    private static func bleedsToEdges(_ image: NSImage) -> Bool {
        if let hit = bleeds.object(forKey: image) { return hit.boolValue }
        let side = 16
        var result = false
        if image.size.width > 0, image.size.height > 0,
           let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
           let context = NSGraphicsContext(bitmapImageRep: bitmap) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            // Aspect-fit, as the tile draws it, so a wide logo's empty bands count as gaps.
            let scale = CGFloat(side) / max(image.size.width, image.size.height)
            let fitted = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: NSRect(x: (CGFloat(side) - fitted.width) / 2, y: (CGFloat(side) - fitted.height) / 2,
                                  width: fitted.width, height: fitted.height))
            NSGraphicsContext.restoreGraphicsState()
            let last = side - 1
            result = (0..<side).allSatisfy { i in
                [(i, 0), (i, last), (0, i), (last, i)].allSatisfy { (bitmap.colorAt(x: $0.0, y: $0.1)?.alphaComponent ?? 0) > 0.9 }
            }
        }
        bleeds.setObject(NSNumber(value: result), forKey: image)
        return result
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        Button(action: open) {
            VStack(spacing: 8) {
                ZStack {
                    shape.fill(Theme.surfaceHover)
                    if let image = store.image(forURL: record.url), Self.isTileArtwork(image) {
                        Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                            .padding(Self.bleedsToEdges(image) ? 0 : 8)
                    } else {
                        FaviconImage(url: record.url, size: 32)
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(shape)
                .overlay(shape.strokeBorder(Theme.border, lineWidth: Theme.Size.hairline))
                .scaleEffect(hovering ? 1.05 : 1)
                Text(record.title.isEmpty ? host : record.title)
                    .font(.callout).lineLimit(2).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(record.url)
        .contextMenu { if let remove { Button("Remove Bookmark", action: remove) } }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
