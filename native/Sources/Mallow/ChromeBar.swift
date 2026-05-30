// ChromeBar — the custom titlebar overlay (View layer), matching Mallow's transparent titlebar:
// the centered filename + ● modified dot, and the style / export / info corner buttons. It only
// builds + wires the views; the actions live on the EditorController (the responder).

import AppKit

/// A 30×30 rounded titlebar button with an SF-Symbol icon — matches Mallow's `.corner-btn`.
func cornerButton(_ symbol: String, _ target: AnyObject, _ action: Selector) -> NSButton {
    let b = NSButton()
    b.translatesAutoresizingMaskIntoConstraints = false
    b.isBordered = false
    b.title = ""
    b.imagePosition = .imageOnly
    b.wantsLayer = true
    b.layer?.backgroundColor = cornerBtnFill.cgColor
    b.layer?.cornerRadius = 8
    b.layer?.borderWidth = 1
    b.layer?.borderColor = NSColor(white: 1, alpha: 0.08).cgColor
    let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
    b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
    b.contentTintColor = mallowDim
    b.target = target
    b.action = action
    NSLayoutConstraint.activate([
        b.widthAnchor.constraint(equalToConstant: 30),
        b.heightAnchor.constraint(equalToConstant: 30),
    ])
    return b
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
    let center = NSStackView(views: [dot, name])
    center.spacing = 6
    center.alignment = .centerY
    center.translatesAutoresizingMaskIntoConstraints = false
    bar.addSubview(center)

    let right = NSStackView(views: [
        cornerButton("textformat", c, #selector(EditorController.showStyleMenu(_:))),
        cornerButton("arrow.down.doc", c, #selector(EditorController.exportPDF(_:))),
        cornerButton("info.circle", c, #selector(EditorController.showInfo(_:))),
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
