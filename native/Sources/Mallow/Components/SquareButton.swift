// SquareButton — the one reusable 1:1 (width==height) chrome button (View layer). The titlebar's
// `CornerButton` and the Style popover's `StyleButton` were two near-identical HoverButton subclasses,
// each re-implementing the same fill/border/tint-on-hover dance against `layer.backgroundColor`. This
// folds both into a single configurable button: a `SquareButton.Config` carries the size/radius, the
// content (an SF symbol OR an attributed label), the rest/hover/active fills, the optional border
// colors, and the optional icon tint. The square shape is guaranteed by equal width+height constraints,
// so callers can never accidentally make a non-square (or differently-sized) button again.
//
// Hover + pressed ride on the HoverButton base: `hoverChanged()` re-runs the restyle, and
// `appearanceDidChange()` re-applies it under the new appearance — the layer fills/border are CGColor
// snapshots that do NOT re-resolve on a light↔dark flip, so they must be re-pushed there. A `pressed`
// (mouseDown) state exists only when an active fill is configured, mirroring the old CornerButton.

import AppKit

/// A fixed-size square HoverButton. Build one from a `Config`; the equal width/height constraints make
/// it 1:1 by construction. Subclassing is not needed — `CornerButton`/`StyleButton` are thin factories
/// that hand this the right `Config`.
final class SquareButton: HoverButton {
    /// The button's content: either an SF-Symbol name (rendered via `symbolImage` at the given point
    /// size/weight and tinted via `tint`) or a ready-made attributed label (which carries its own
    /// colors, so `tint` is ignored for it).
    enum Content {
        case symbol(String, pointSize: CGFloat, weight: NSFont.Weight = .regular)
        case label(NSAttributedString)
    }

    /// Everything that makes one square button. `activeFill == nil` means no pressed state; `border ==
    /// nil` means no border (borderWidth 0); `tint == nil` means leave `contentTintColor` untouched
    /// (used by label content, whose colors live in the attributed string).
    struct Config {
        var size: CGFloat
        var cornerRadius: CGFloat
        var content: Content
        /// Layer fills for rest / hover / pressed. `active` nil ⇒ the button has no pressed state.
        var fill: NSColor
        var hoverFill: NSColor
        var activeFill: NSColor?
        /// 1px border colors for rest / hover. nil ⇒ no border.
        var border: NSColor?
        var hoverBorder: NSColor?
        /// SF-symbol tint for rest / hover. nil ⇒ don't set `contentTintColor` (label content).
        var tint: NSColor?
        var hoverTint: NSColor?
    }

    private let config: Config
    /// True between mouseDown and the end of the click loop — only ever set when `activeFill` exists.
    private var pressed = false { didSet { if pressed != oldValue { restyle() } } }

    init(_ config: Config, target: AnyObject, action: Selector) {
        self.config = config
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        bezelStyle = .shadowlessSquare
        imagePosition = .imageOnly
        wantsLayer = true
        layer?.cornerRadius = config.cornerRadius
        layer?.borderWidth = config.border == nil ? 0 : 1
        self.target = target
        self.action = action

        switch config.content {
        case .symbol(let name, let pointSize, let weight):
            title = ""
            image = symbolImage(name, pointSize: pointSize, weight: weight)
            imagePosition = .imageOnly
        case .label(let attr):
            title = ""
            attributedTitle = attr
            imagePosition = .noImage
        }

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: config.size),
            heightAnchor.constraint(equalToConstant: config.size),
        ])
        restyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Apply fill + border + tint for the current state (pressed beats hover beats rest). Called on
    /// init, on every hover/pressed transition, and on an appearance flip — so the CGColor snapshots
    /// always match the live appearance.
    private func restyle() {
        let fillColor = (pressed ? config.activeFill : nil) ?? (hovering ? config.hoverFill : config.fill)
        layer?.backgroundColor = fillColor.cgColor
        if let border = config.border {
            layer?.borderColor = (hovering ? (config.hoverBorder ?? border) : border).cgColor
        }
        if let tint = config.tint {
            contentTintColor = hovering ? (config.hoverTint ?? tint) : tint
        }
    }

    override func hoverChanged() { restyle() }
    override func appearanceDidChange() { restyle() }   // re-resolve layer fill + border + tint for the new appearance

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        pressed = false
    }
    override func mouseDown(with event: NSEvent) {
        guard config.activeFill != nil else { super.mouseDown(with: event); return }
        pressed = true
        super.mouseDown(with: event)   // runs the button's own click-tracking loop, sends the action
        pressed = false
    }
}
