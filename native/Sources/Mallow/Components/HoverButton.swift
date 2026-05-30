// HoverButton — the shared NSButton hover-tracking base (View-layer plumbing). Every custom button in
// Mallow's chrome restyles itself on mouse hover (the WebView's `:hover` rules), and they all hand-
// rolled the IDENTICAL tracking-area lifecycle + a `hovering` flag. This collapses that boilerplate to
// one place: subclasses just override `hoverChanged()` to do their restyle. The tracking area is
// rebuilt in `updateTrackingAreas` (so it follows bounds changes) and observes the whole app
// (`.activeAlways`, `.inVisibleRect`); `hoverChanged()` fires only on an actual transition.

import AppKit

/// An NSButton that tracks pointer hover for you. Subclasses read `hovering` and override
/// `hoverChanged()` to update their fill/border/tint. The base owns the NSTrackingArea lifecycle and
/// the enter/exit events; it deliberately does NOT touch any visuals itself (subclasses own all styling).
class HoverButton: NSButton {
    /// True while the pointer is inside the button. `didSet` calls `hoverChanged()` only when the value
    /// actually flips, so a subclass restyle never runs redundantly.
    private(set) var hovering = false {
        didSet { if hovering != oldValue { hoverChanged() } }
    }

    /// Override to restyle for the current `hovering` state. Default: nothing.
    func hoverChanged() {}

    /// Re-apply any layer (CGColor) styling when the effective appearance flips (light↔dark). A CGColor
    /// is a static snapshot of a resolved color — unlike an NSColor on `fillColor`/`textColor`, it does
    /// NOT re-resolve when the appearance changes — so subclasses that push dynamic tokens onto their
    /// layer must re-run that here. The re-apply runs inside the new appearance so the tokens resolve
    /// against it. Default: nothing (subclasses with layer colors override).
    func appearanceDidChange() {}

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { self.appearanceDidChange() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
}
