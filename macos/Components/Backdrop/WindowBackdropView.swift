import AppKit
import SwiftUI

/// The window's backdrop (`WindowBackdrop`): the title bar's material, which lets the desktop's own
/// colour through where the sidebar's material greys it, under the wash. The material blends with
/// what is behind the window, so it covers AppKit's own sidebar and inspector materials under it. It
/// stays active in a window in the background: a material gone inactive flattens under the same
/// wash, and the backdrop would change shade with the window's focus.
final class WindowBackdropView: NSVisualEffectView {
    private let wash = BackdropWash()

    /// How much of the wash is laid on (`WindowBackdrop.opacity`).
    var washOpacity: Double = 1 { didSet { wash.alphaValue = washOpacity } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .titlebar
        blendingMode = .behindWindow
        state = .active
        wash.translatesAutoresizingMaskIntoConstraints = false
        addSubview(wash)
        NSLayoutConstraint.activate([
            wash.leadingAnchor.constraint(equalTo: leadingAnchor),
            wash.trailingAnchor.constraint(equalTo: trailingAnchor),
            wash.topAnchor.constraint(equalTo: topAnchor),
            wash.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// The backdrop's wash: colour only, so neither VoiceOver nor the pointer finds it. A layer takes a
/// resolved colour, so it is resolved again when the appearance changes.
private final class BackdropWash: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func paint() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = Theme.backdropWash.cgColor }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        paint()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }
}

/// The backdrop behind a SwiftUI column.
private struct WindowBackdropRepresentable: NSViewRepresentable {
    let opacity: Double

    func makeNSView(context: Context) -> WindowBackdropView {
        let view = WindowBackdropView()
        view.washOpacity = opacity
        return view
    }

    func updateNSView(_ view: WindowBackdropView, context: Context) { view.washOpacity = opacity }
}

extension View {
    /// A window column's root: on the window's backdrop while translucent, and the one place the
    /// switch enters the environment for everything the column draws.
    func windowBackdrop(_ backdrop: WindowBackdrop) -> some View {
        background {
            if backdrop.isTranslucent { WindowBackdropRepresentable(opacity: backdrop.opacity).ignoresSafeArea() }
        }
        .environment(\.windowTranslucent, backdrop.isTranslucent)
    }

    /// A surface's own opaque page colour, dropped while translucent so the window's backdrop shows
    /// through rather than a solid panel sitting on it.
    func paneSurface(ignoresSafeAreaEdges edges: Edge.Set = .all) -> some View {
        modifier(PaneSurfaceModifier(edges: edges))
    }

    /// A control's fill — a pill, a capsule, the selected tab — thinned while translucent, so the
    /// window's backdrop shows through it as through the bar it sits in. Its outline keeps the shape.
    func backdropFill<S: Shape>(_ color: Color, in shape: S) -> some View {
        background { BackdropFill(color: color, shape: shape) }
    }

    /// A list's or table's own content background, hidden while translucent for the same reason.
    func backdropContentBackground() -> some View { modifier(BackdropContentBackgroundModifier()) }
}

/// A shape in a control's colour, at `WindowBackdrop.controlOpacity` while translucent.
struct BackdropFill<S: Shape>: View {
    let color: Color
    let shape: S
    @Environment(\.windowTranslucent) private var translucent

    var body: some View { shape.fill(color.opacity(translucent ? WindowBackdrop.controlOpacity : 1)) }
}

private struct BackdropContentBackgroundModifier: ViewModifier {
    @Environment(\.windowTranslucent) private var translucent

    func body(content: Content) -> some View {
        content.scrollContentBackground(translucent ? .hidden : .automatic)
    }
}

private struct PaneSurfaceModifier: ViewModifier {
    let edges: Edge.Set
    @Environment(\.windowTranslucent) private var translucent

    func body(content: Content) -> some View {
        content.background(translucent ? Color.clear : Theme.paneBackground, ignoresSafeAreaEdges: edges)
    }
}
