import SwiftUI

// Reusable pieces built from `DesignTokens.swift`. Deliberately small: Settings is composed of
// native `Form` sections, where a card container or a custom button style reads as less native
// than the system's own. Add those back alongside the first screen that actually needs them.

// MARK: - Layout

extension View {
    /// The renderer's capped, centred page column (`max-width:760px`).
    func readableColumn(_ width: CGFloat = Theme.Size.readableColumn) -> some View {
        frame(maxWidth: width).frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - Controls

extension View {
    /// Icon-only toolbar buttons at the large control size, each glyph in the same square so every
    /// button is the same size: round Liquid Glass on macOS 26 and later, the system's default
    /// button look before that.
    @ViewBuilder func glassIconButtons() -> some View {
        let sized = labelStyle(SquareIconLabelStyle()).controlSize(.large)
        if #available(macOS 26.0, *) { sized.buttonStyle(.glass).buttonBorderShape(.circle) } else { sized }
    }

    /// A plain text field in a tinted capsule with a hairline border, as tall as the large round
    /// buttons beside it.
    func capsuleField() -> some View {
        textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .frame(height: Theme.Size.largeControl)
            .background(Theme.surfaceHover, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.border, lineWidth: Theme.Size.hairline))
    }
}

/// Just the icon, centred in a fixed square, so glyphs of different widths make equal buttons.
/// The title stays on the label as its accessibility name, as with `.iconOnly`.
struct SquareIconLabelStyle: LabelStyle {
    var side: CGFloat = 20
    func makeBody(configuration: Configuration) -> some View {
        Label {
            configuration.title
        } icon: {
            configuration.icon.frame(width: side, height: side)
        }
        .labelStyle(.iconOnly)
    }
}

// MARK: - Status tints

/// The semantic tint pairs the web uses for badges and pills. One case per `--*-bg` / `--*` pair.
enum ThemeTone: Sendable {
    case neutral, success, warning, danger, accent, merged

    var foreground: Color {
        switch self {
        case .neutral: Theme.textSecondary
        case .success: Theme.success
        case .warning: Theme.warn
        case .danger: Theme.danger
        case .accent: Theme.accent
        case .merged: Theme.merged
        }
    }
    var background: Color {
        switch self {
        case .neutral: Theme.surfaceHover
        case .success: Theme.successBackground
        case .warning: Theme.warnBackground
        case .danger: Theme.dangerBackground
        case .accent: Theme.accentBackground
        case .merged: Theme.mergedBackground
        }
    }
}

/// The web `.hook-pill`: a bordered status pill. A tinted tone drops the border, as the CSS does.
struct StatusPill: View {
    let text: String
    var tone: ThemeTone = .neutral
    /// Goes on the inner `Text` so UI tests still resolve the pill through `staticTexts`.
    var identifier: String?

    var body: some View {
        Text(text)
            .accessibilityIdentifier(identifier ?? "")
            .font(Theme.Typography.pill)
            .foregroundStyle(tone.foreground)
            .padding(.horizontal, 9)
            .padding(.vertical, 2)
            .background(Capsule().fill(tone.background))
            .overlay(
                Capsule().strokeBorder(tone == .neutral ? Theme.border : .clear,
                                       lineWidth: Theme.Size.hairline)
            )
    }
}

// MARK: - Slider

/// A tick under a slider marking where the default sits, so "what was this originally?" stays
/// visible without spending a row on text or a Reset button. Decorative: callers put the number
/// in `.help` / the slider's accessibility value.
struct SliderDefaultMarker: View {
    let value: Double
    let range: ClosedRange<Double>
    /// Half the slider knob — the track is inset by this much at both ends.
    var knobInset: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            let span = range.upperBound - range.lowerBound
            let fraction = span == 0 ? 0 : (value - range.lowerBound) / span
            let track = max(0, geo.size.width - knobInset * 2)
            Image(systemName: "arrowtriangle.up.fill")
                .font(.system(size: 6))
                .foregroundStyle(Theme.textTertiary)
                .position(x: knobInset + track * fraction, y: 4)
        }
        .frame(height: 9)
        .accessibilityHidden(true)
    }
}
