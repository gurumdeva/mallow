// MallowControls — the shared SwiftUI control primitives, the declarative replacement for the AppKit
// HoverButton / SquareButton / UIComponents factories. `SquareButtonStyle` is the one 1:1 square button
// (titlebar corner buttons + style-card buttons) with hover + pressed + optional border, mirroring the
// CSS `.corner-btn` / `.style-btn` states. Colors come from the `Theme.*` tokens so light/dark tracks
// the editor. Keeping these here means the chrome and the popovers share exactly one button look.

import SwiftUI

/// A fixed-size (1:1) square button. Fill is pressed → hover → rest; an optional 1px border can also
/// react to hover. `tint`/`hoverTint` recolor SF-symbol/label content (pass nil to leave the label's
/// own foreground). The square shape is guaranteed by the equal width/height frame.
struct SquareButtonStyle: ButtonStyle {
    var size: CGFloat
    var cornerRadius: CGFloat
    var fill: Color
    var hoverFill: Color
    var activeFill: Color? = nil
    var border: Color? = nil
    var hoverBorder: Color? = nil
    var tint: Color? = nil
    var hoverTint: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        SquareButtonBody(configuration: configuration, style: self)
    }

    /// Hover needs view state, so the body is its own View (a ButtonStyle struct can't hold @State that
    /// survives recomposition reliably).
    private struct SquareButtonBody: View {
        let configuration: Configuration
        let style: SquareButtonStyle
        @State private var hovering = false

        var body: some View {
            let pressed = configuration.isPressed
            let bg = pressed ? (style.activeFill ?? style.hoverFill) : (hovering ? style.hoverFill : style.fill)
            let stroke = hovering ? (style.hoverBorder ?? style.border) : style.border
            let fg = hovering ? (style.hoverTint ?? style.tint) : style.tint
            return configuration.label
                .modifier(OptionalTint(color: fg))
                .frame(width: style.size, height: style.size)
                .background(RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous).fill(bg))
                .overlay(
                    RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                        .strokeBorder(stroke ?? .clear, lineWidth: stroke == nil ? 0 : 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous))
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.08), value: pressed)
        }
    }
}

/// Apply `foregroundStyle` only when a tint is supplied (label content otherwise keeps its own colors).
private struct OptionalTint: ViewModifier {
    let color: Color?
    func body(content: Content) -> some View {
        if let color { content.foregroundStyle(color) } else { content }
    }
}

extension SquareButtonStyle {
    /// The titlebar corner button (style / export / info): 30×30, radius 8, the corner-btn fills, a
    /// --border hairline, and a dim→text tint on hover. Matches CSS `.corner-btn`.
    static var corner: SquareButtonStyle {
        SquareButtonStyle(size: 30, cornerRadius: 8,
                          fill: Theme.cornerFill, hoverFill: Theme.cornerFillHover, activeFill: Theme.cornerFillActive,
                          border: Theme.border, hoverBorder: Theme.border,
                          tint: Theme.dim, hoverTint: Theme.text)
    }

    /// The style-card button (H1 / quote / bold …): a fixed 44×44 surface card, radius 10, with a
    /// stronger border on hover. Matches CSS `.style-btn`. Label content carries its own color.
    static var styleCard: SquareButtonStyle {
        SquareButtonStyle(size: 44, cornerRadius: 10,
                          fill: Theme.card, hoverFill: Theme.cardHover,
                          border: Theme.border, hoverBorder: Theme.strongBorder,
                          tint: Theme.text, hoverTint: Theme.text)
    }
}
