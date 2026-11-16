import AppKit
import Foundation
import Observation
import SwiftUI
import Testing

/// The pane's flat tab strip, closing tabs from the leading end, the trailing end and the middle
/// and opening them in the same places, drawn in a real window and read back frame by frame while
/// a closed tab folds into its leading edge or a new one opens out of it.

@MainActor @Observable private final class StripTabs {
    var ids: [String]
    var active: String?
    /// Tabs opened and closed, as `WorkspaceContext.tabEdits`: what the row animates on.
    var edits = 0
    init(_ ids: [String], active: String?) { self.ids = ids; self.active = active }

    /// As the pane closes a tab: the selected one hands the selection to its nearest neighbour.
    func close(_ id: String) {
        guard let index = ids.firstIndex(of: id) else { return }
        ids.remove(at: index); edits += 1
        if active == id { active = ids.isEmpty ? nil : ids[min(index, ids.count - 1)] }
    }

    /// As the pane opens a tab: in its place, and selected.
    func open(_ id: String, at index: Int) {
        ids.insert(id, at: index); edits += 1
        active = id
    }
}

/// What each tab view showed, by the storage it was drawn with: a storage seen under two ids is a
/// view SwiftUI reused for another tab.
@MainActor private final class ProbeLog {
    var shown: [UUID: Set<String>] = [:]
    func saw(_ id: String, _ token: UUID) { shown[token, default: []].insert(id) }
    var reused: [Set<String>] { shown.values.filter { $0.count > 1 } }
}

private struct Probe: View {
    let id: String
    let color: NSColor
    let log: ProbeLog
    @State private var token = UUID()
    var body: some View {
        Rectangle().fill(Color(nsColor: color))
            .frame(maxWidth: .infinity).frame(height: 28)
            .onChange(of: id, initial: true) { _, id in log.saw(id, token) }
    }
}

private let probeColors: [String: NSColor] = [
    "A": NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), "B": NSColor(srgbRed: 0, green: 0.8, blue: 0, alpha: 1),
    "C": NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1), "D": NSColor(srgbRed: 1, green: 0.8, blue: 0, alpha: 1),
    "E": NSColor(srgbRed: 0.8, green: 0, blue: 0.8, alpha: 1), "F": NSColor(srgbRed: 0, green: 0.8, blue: 0.8, alpha: 1),
]

private struct StripHost: View {
    let tabs: StripTabs
    let log: ProbeLog
    var body: some View {
        CompactTabPill(ids: tabs.ids, activeID: tabs.active, available: 1000, maxTabWidth: 150,
                       select: { tabs.active = $0 }, move: { _, _ in }, scope: "strip") { id, _ in
            // As the pane draws a tab: from the model, so a tab that has closed has nothing to draw.
            if tabs.ids.contains(id) { Probe(id: id, color: probeColors[id]!, log: log) }
        }
        .environment(\.compactTabStyle, .flat)
        // As the pane's row (`BrowserCompactTabBar`): opening and closing tabs animate.
        .animation(.snappy(duration: 0.3), value: tabs.edits)
        .frame(width: 1000, height: 40, alignment: .leading)
        .background(Color.white)
    }
}

private typealias StripCapture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

/// One run of a tab's colour across the row, in points.
private struct Run: Equatable { let name: String; let start: Int; let end: Int; var width: Int { end - start + 1 } }

/// The row as runs of tab colours, the strip's own background left out.
@MainActor private func runs(_ bitmap: NSBitmapImageRep, scale: CGFloat) -> [Run] {
    var result: [Run] = []
    var current: String?, start = 0
    let y = bitmap.pixelsHigh / 2
    for x in 0...1000 {
        var name = "_"
        if x < 1000, let pixel = bitmap.colorAt(x: Int((CGFloat(x) + 0.5) * scale), y: y)?.usingColorSpace(.sRGB),
           pixel.saturationComponent > 0.3, pixel.brightnessComponent > 0.4 {
            // By hue: the capture comes back in the display's colour space, so exact values drift.
            let best = probeColors.min { hueDistance($0.value.hueComponent, pixel.hueComponent) < hueDistance($1.value.hueComponent, pixel.hueComponent) }!
            name = hueDistance(best.value.hueComponent, pixel.hueComponent) < 0.06 ? best.key : "?"
        }
        if name != current {
            if let current, current != "_" { result.append(Run(name: current, start: start, end: x - 1)) }
            current = name; start = x
        }
    }
    // Mid-slide a tab stands on a fraction of a point, and the rule before it can cut a pixel off its
    // edge: one tab's runs that close a gap that small are one run.
    return result.reduce(into: []) { merged, run in
        if let last = merged.last, last.name == run.name, run.start - last.end <= 3 {
            merged[merged.count - 1] = Run(name: run.name, start: last.start, end: run.end)
        } else { merged.append(run) }
    }
}

private func hueDistance(_ a: CGFloat, _ b: CGFloat) -> CGFloat { min(abs(a - b), 1 - abs(a - b)) }

private func describe(_ runs: [Run]) -> String { runs.map { "\($0.name)\($0.start)-\($0.end)" }.joined(separator: " ") }

/// Makes `change` to A…E with `active` selected, drawing each tab as the pane does — from the model,
/// so a closed tab has nothing of its own to draw — and records the strip for half a second.
@MainActor private func record(active: String, change: (StripTabs) -> Void) async throws -> (before: [Run], frames: [(ms: Double, runs: [Run])], after: [Run], reused: [Set<String>]) {
    _ = NSApplication.shared
    let capture = unsafeBitCast(try #require(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage")), to: StripCapture.self)
    let tabs = StripTabs(["A", "B", "C", "D", "E"], active: active)
    let log = ProbeLog()
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = NSHostingView(rootView: StripHost(tabs: tabs, log: log))
    window.orderFrontRegardless()
    defer { window.close() }
    func frame() throws -> [Run] {
        let image = try #require(capture(.null, 1 << 3, UInt32(window.windowNumber), 1 | 8)?.takeRetainedValue())
        let bitmap = NSBitmapImageRep(cgImage: image)
        return runs(bitmap, scale: CGFloat(bitmap.pixelsWide) / 1000)
    }
    try await Task.sleep(for: .milliseconds(400))
    let before = try frame()
    change(tabs)
    var frames: [(ms: Double, runs: [Run])] = []
    let start = Date()
    while Date().timeIntervalSince(start) < 0.5 {
        try await Task.sleep(for: .milliseconds(10))
        frames.append((Date().timeIntervalSince(start) * 1000, try frame()))
    }
    try await Task.sleep(for: .milliseconds(300))
    return (before, frames, try frame(), log.reused)
}

private typealias Recording = (before: [Run], frames: [(ms: Double, runs: [Run])], after: [Run], reused: [Set<String>])

/// The first frame that changed, if it came soon enough to show the animation's start.
private func early(_ recording: Recording) -> (ms: Double, runs: [Run])? {
    recording.frames.first { $0.runs != recording.before }.flatMap { $0.ms < 200 ? $0 : nil }
}

/// Records `change`, again when the first changed frame came too late to show the animation: the
/// main actor was busy (the rest of the suite runs alongside), and such a run says nothing.
@MainActor private func recordInTime(active: String, inTime: (Recording) -> Bool = { early($0) != nil },
                                      change: (StripTabs) -> Void) async throws -> Recording {
    var recording = try await record(active: active, change: change)
    for _ in 0..<4 where !inTime(recording) { recording = try await record(active: active, change: change) }
    return recording
}

/// Writes a run's frames to `$PANE_TABS_REPORT/<name>.txt` when that is set (pass it to the test
/// process as `TEST_RUNNER_PANE_TABS_REPORT`), to read what the strip did.
private func dump(_ recording: Recording, as name: String) {
    guard let folder = ProcessInfo.processInfo.environment["PANE_TABS_REPORT"] else { return }
    try? report(recording).write(toFile: "\(folder)/\(name).txt", atomically: true, encoding: .utf8)
}

private func report(_ recording: Recording) -> String {
    "before: \(describe(recording.before))\n" + recording.frames.map { String(format: "%3.0fms ", $0.ms) + describe($0.runs) }.joined(separator: "\n")
        + "\nafter: \(describe(recording.after))"
}

/// What holds while any tab comes or goes: only the tabs' own colours, in their order, the tabs
/// before the one changing never moving, and no tab's view drawn for another.
private func expectSteady(_ recording: Recording, order names: [String], changing: String, label: String) {
    #expect(recording.reused.isEmpty, "\(label): a view drawn for one tab was reused for another: \(recording.reused)")
    let index = names.firstIndex(of: changing) ?? 0
    let leading = Array(recording.before.prefix(index))
    for (number, frame) in recording.frames.enumerated() {
        let runs = frame.runs
        #expect(!runs.contains { $0.name == "?" }, "\(label) frame \(number): \(describe(runs))")
        #expect(runs.map(\.name) == names.filter { runs.map(\.name).contains($0) }, "\(label) frame \(number) out of order: \(describe(runs))")
        #expect(Array(runs.prefix(index)) == leading, "\(label) frame \(number): the tabs before moved: \(describe(runs))")
    }
}

@MainActor @Test(.timeLimit(.minutes(1)), .serialized, arguments: [
    ("A", "C"), ("E", "C"), ("C", "C"), ("B", "C"), ("A", "A"), ("E", "E"), ("D", "B"),
]) func aClosedPaneTabFoldsItsOwnSlotAndReusesNoView(closing: String, active: String) async throws {
    let label = "close \(closing), active \(active)"
    let recording = try await recordInTime(active: active) { $0.close(closing) }
    dump(recording, as: "close-\(closing)-\(active)")
    let names = ["A", "B", "C", "D", "E"]
    #expect(recording.before.map(\.name) == names, "\(label): \(describe(recording.before))")
    #expect(recording.after.map(\.name) == names.filter { $0 != closing }, "\(label): \(describe(recording.after))")
    expectSteady(recording, order: names, changing: closing, label: label)
    // The first frame that changed shows the closed tab still there, narrowing in its own slot:
    // not gone, with the tab after it already in its place.
    let order = try #require(names.firstIndex(of: closing))
    let first = try #require(early(recording), "\(label): never sampled the fold in time:\n\(report(recording))")
    let folding = first.runs.first { $0.name == closing }
    #expect(folding.map { $0.start == recording.before[order].start && $0.width > 0 } == true,
            "\(label): at \(Int(first.ms))ms the closed tab is \(folding.map { "\($0.start)-\($0.end)" } ?? "gone"):\n\(report(recording))")
    if order + 1 < names.count, let folding {
        let next = first.runs.first { $0.name == names[order + 1] }
        #expect(next.map { abs($0.start - (folding.end + 1 + Int(CompactTabMetrics.tabSpacing))) <= 2 } == true,
                "\(label): the tab after it does not follow its edge:\n\(report(recording))")
    }
    // And it only ever narrows.
    let widths = recording.frames.map { $0.runs.first { $0.name == closing }?.width ?? 0 }
    #expect(zip(widths, widths.dropFirst()).allSatisfy { $1 <= $0 + 1 }, "\(label): the closed tab widened: \(widths)")
}

/// The other way round: a new tab opens out of its leading edge, its slot widening from nothing,
/// and the tabs after it move with its trailing edge.
@MainActor @Test(.timeLimit(.minutes(1)), .serialized, arguments: [0, 2, 5])
func anOpenedPaneTabWidensFromItsLeadingEdge(at index: Int) async throws {
    let label = "open F at \(index)"
    // In time when the new tab's first frame on screen came soon enough to show it opening.
    let recording = try await recordInTime(active: "C", inTime: { recording in
        early(recording) != nil && (recording.frames.first { $0.runs.contains { $0.name == "F" } }?.ms ?? .infinity) < 250
    }) { $0.open("F", at: index) }
    dump(recording, as: "open-\(index)")
    var names = ["A", "B", "C", "D", "E"]
    #expect(recording.before.map(\.name) == names, "\(label): \(describe(recording.before))")
    names.insert("F", at: index)
    #expect(recording.after.map(\.name) == names, "\(label): \(describe(recording.after))")
    expectSteady(recording, order: names, changing: "F", label: label)
    // Where the tab it opens before stood, or the end of the last: its slot starts there.
    let slot = index < recording.before.count ? recording.before[index].start
        : (recording.before.last.map { $0.end + 1 + Int(CompactTabMetrics.tabSpacing) } ?? 0)
    // The first frame it shows in, once the change began: a frame before can move the others by a
    // fraction of a point while its own slot is still under one.
    let first = try #require(recording.frames.first { $0.runs.contains { $0.name == "F" } },
                             "\(label): it never showed:\n\(report(recording))")
    #expect(early(recording) != nil && first.ms < 250, "\(label): it showed only at \(Int(first.ms))ms:\n\(report(recording))")
    let opening = try #require(first.runs.first { $0.name == "F" })
    let full = try #require(recording.after.first { $0.name == "F" }).width
    #expect(opening.start == slot && opening.width < full, "\(label): at \(Int(first.ms))ms it is \(opening.start)-\(opening.end), not part of its slot from \(slot):\n\(report(recording))")
    if index < 5 {
        let next = first.runs.first { $0.name == names[index + 1] }
        #expect(next.map { abs($0.start - (opening.end + 1 + Int(CompactTabMetrics.tabSpacing))) <= 2 } == true,
                "\(label): the tab after it does not follow its edge:\n\(report(recording))")
    }
    // It only ever widens.
    let widths = recording.frames.map { $0.runs.first { $0.name == "F" }?.width ?? 0 }
    #expect(zip(widths, widths.dropFirst()).allSatisfy { $1 + 1 >= $0 }, "\(label): the new tab narrowed: \(widths)")
}

