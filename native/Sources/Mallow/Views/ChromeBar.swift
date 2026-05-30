// ChromeBar — the custom titlebar overlay (View layer), matching Mallow's transparent titlebar:
// the centered filename + ● modified dot, and the style / export / info corner buttons. It only
// builds + wires the views; the actions live on the EditorController (the responder).

import AppKit

/// A 30×30 rounded titlebar button with an SF-Symbol icon — matches Mallow's `.corner-btn`, including
/// the fill + icon-tint changes on hover/active (style.css `.corner-btn:hover` / `:active`). The bare
/// NSButton was static; this restores the three interaction states the WebView version has.
final class CornerButton: HoverButton {
    private var pressed = false { didSet { refreshFill() } }

    convenience init(symbol: String, target: AnyObject, action: Selector) {
        self.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        title = ""
        imagePosition = .imageOnly
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        image = symbolImage(symbol, pointSize: 13, weight: .medium)
        self.target = target
        self.action = action
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 30),
            heightAnchor.constraint(equalToConstant: 30),
        ])
        refreshFill()
    }

    /// Fill + border + icon tint for the current state (active beats hover beats rest), matching the CSS
    /// rules. Border (--border) is set here, not just at init, so it re-resolves on an appearance flip.
    private func refreshFill() {
        let fill = pressed ? cornerBtnFillActive : (hovering ? cornerBtnFillHover : cornerBtnFill)
        layer?.backgroundColor = fill.cgColor
        layer?.borderColor = mallowBorderColor.cgColor   // --border
        contentTintColor = hovering ? mallowText : mallowDim   // :hover { color: var(--text) }
    }

    override func hoverChanged() { refreshFill() }
    override func appearanceDidChange() { refreshFill() }   // re-resolve layer fill + border for new appearance
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); pressed = false }
    override func mouseDown(with event: NSEvent) {
        pressed = true
        super.mouseDown(with: event)   // runs the button's own click-tracking loop, sends the action
        pressed = false
    }
}

/// Factory kept so the chrome-bar call sites stay unchanged; returns the interactive CornerButton.
func cornerButton(_ symbol: String, _ target: AnyObject, _ action: Selector) -> NSButton {
    CornerButton(symbol: symbol, target: target, action: action)
}

/// The centered filename as a real NSButton (CSS `.titlebar-center`: `radius 7`, hover → elevated bg +
/// brighter text). An NSButton — not a label — because a control reliably receives the click; a plain
/// label let `isMovableByWindowBackground` swallow it as a window drag, so rename never fired. Click →
/// renameFromTitlebar; truncates long names.
final class FilenameButton: HoverButton {
    private var name = "Untitled"

    convenience init(target: AnyObject, action: Selector) {
        self.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        bezelStyle = .inline
        imagePosition = .noImage
        wantsLayer = true
        layer?.cornerRadius = 7
        lineBreakMode = .byTruncatingTail
        self.target = target
        self.action = action
        refresh()
    }

    /// Set the displayed filename (mirrors the old label's stringValue).
    func setName(_ s: String) { name = s; refresh() }

    private func refresh() {
        layer?.backgroundColor = (hovering ? mallowElevated : NSColor.clear).cgColor
        attributedTitle = NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: hovering ? mallowText : mallowDim,
        ])
    }

    override func hoverChanged() { refresh() }
    override func appearanceDidChange() { refresh() }   // re-resolve the layer bg for the new appearance
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The opaque titlebar backdrop. Its `mallowBG` fill is pushed onto the layer as a CGColor, which is a
/// static snapshot and would NOT re-resolve on a light↔dark flip — so this re-applies it whenever the
/// effective appearance changes (and once on insertion), keeping the bar in step with the system. The
/// fill is the dynamic `mallowBG` token, so dark stays byte-identical; only the new light path is added.
private final class ChromeBackdrop: NSView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.layer?.backgroundColor = mallowBG.cgColor
        }
    }
}

/// The 52px titlebar overlay (opaque): centered filename + ● dot, and the style / export / info
/// corner buttons on the right. Wires the buttons + the filename/dot refs onto `c`.
func makeChromeBar(_ c: EditorController) -> NSView {
    let bar = ChromeBackdrop()
    bar.translatesAutoresizingMaskIntoConstraints = false
    bar.wantsLayer = true
    bar.layer?.backgroundColor = mallowBG.cgColor

    let dot = mallowLabel("●", size: 9, color: mallowDim)
    dot.isHidden = true
    // Click the centered filename to rename the file on disk (RenameInTitlebar.swift). A real button
    // (not a label) so the click isn't swallowed as a window drag.
    let nameButton = FilenameButton(target: c, action: #selector(EditorController.renameFromTitlebar(_:)))
    let center = NSStackView(views: [dot, nameButton])
    center.spacing = 4
    center.alignment = .centerY
    center.translatesAutoresizingMaskIntoConstraints = false
    bar.addSubview(center)

    let right = NSStackView(views: [
        cornerButton("textformat", c, #selector(EditorController.showStyleMenu(_:))),
        cornerButton("arrow.down.doc", c, #selector(EditorController.exportPDF(_:))),
        cornerButton("info.circle", c, #selector(EditorController.showDocumentInfo(_:))),
    ])
    right.spacing = 6
    right.translatesAutoresizingMaskIntoConstraints = false
    bar.addSubview(right)

    NSLayoutConstraint.activate([
        center.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
        center.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        center.widthAnchor.constraint(lessThanOrEqualTo: bar.widthAnchor, multiplier: 0.55),
        right.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -16),
        right.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
    ])
    c.titleButton = nameButton
    c.dotView = dot
    return bar
}
