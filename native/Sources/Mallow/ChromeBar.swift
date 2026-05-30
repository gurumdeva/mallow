// ChromeBar — the custom titlebar overlay (View layer), matching Mallow's transparent titlebar:
// the centered filename + ● modified dot, and the style / export / info corner buttons. It only
// builds + wires the views; the actions live on the EditorController (the responder).

import AppKit

/// A 30×30 rounded titlebar button with an SF-Symbol icon — matches Mallow's `.corner-btn`, including
/// the fill + icon-tint changes on hover/active (style.css `.corner-btn:hover` / `:active`). The bare
/// NSButton was static; this restores the three interaction states the WebView version has.
final class CornerButton: NSButton {
    private var pressed = false { didSet { refreshFill() } }
    private var hovering = false { didSet { refreshFill() } }

    convenience init(symbol: String, target: AnyObject, action: Selector) {
        self.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        title = ""
        imagePosition = .imageOnly
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.08).cgColor   // --border
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        self.target = target
        self.action = action
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 30),
            heightAnchor.constraint(equalToConstant: 30),
        ])
        refreshFill()
    }

    /// Fill + icon tint for the current state (active beats hover beats rest), matching the CSS rules.
    private func refreshFill() {
        let fill = pressed ? cornerBtnFillActive : (hovering ? cornerBtnFillHover : cornerBtnFill)
        layer?.backgroundColor = fill.cgColor
        contentTintColor = hovering ? mallowText : mallowDim   // :hover { color: var(--text) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false; pressed = false }
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

/// The 52px titlebar overlay (opaque): centered filename + ● dot, and the style / export / info
/// corner buttons on the right. Wires the buttons + the filename/dot refs onto `c`.
func makeChromeBar(_ c: EditorController) -> NSView {
    let bar = NSView()
    bar.translatesAutoresizingMaskIntoConstraints = false
    bar.wantsLayer = true
    bar.layer?.backgroundColor = mallowBG.cgColor

    let dot = NSTextField(labelWithString: "●")
    dot.font = NSFont.systemFont(ofSize: 9)
    dot.textColor = mallowDim
    dot.isHidden = true
    let name = NSTextField(labelWithString: "Untitled")
    name.font = NSFont.systemFont(ofSize: 13, weight: .medium)
    name.textColor = mallowDim
    name.lineBreakMode = .byTruncatingTail
    // Click the centered filename to rename the file on disk (RenameInTitlebar.swift). A gesture
    // recognizer keeps `name` a label (so updateChrome's stringValue assignment is unaffected).
    let renameClick = NSClickGestureRecognizer(
        target: c, action: #selector(EditorController.renameFromTitlebar(_:)))
    name.addGestureRecognizer(renameClick)
    let center = NSStackView(views: [dot, name])
    center.spacing = 6
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
    c.titleLabel = name
    c.dotView = dot
    return bar
}
