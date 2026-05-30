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
