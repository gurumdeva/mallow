// StylePopoverPanel — the Text-Style popover (View), the native counterpart of the Tauri
// StylePopover.ts. The titlebar ✏️/Aa corner button opens it; it offers three labelled sections of
// rounded style cards — Heading (H1/H2/H3/Body), Block (quote/bullet/numbered/code/divider), and
// Inline (bold/italic/strikethrough/inline-code) — each wired to the EditorController's existing
// cmd* actions (which run the engine command on the current selection). This replaces the old
// `showStyleMenu` that popped the Format NSMenu by an `item(withTitle:"Format")` lookup — that lookup
// was always nil (the top-level item has no title), so the button did nothing.

import AppKit

/// A rounded "style card" button matching CSS `.style-btn`: surface-card fill, 1px border, radius 10,
/// min-height 40, hover → surface-card-hover + a stronger border. Content is the button's own
/// attributed title or SF-symbol image (no subview, so nothing intercepts the click).
final class StyleButton: HoverButton {
    private func setup(_ target: AnyObject, _ action: Selector) {
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        bezelStyle = .shadowlessSquare
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        self.target = target
        self.action = action
        heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        refresh()
    }

    /// A text card (H1/H2/H3/Body): the label is the button's attributed title.
    convenience init(label: NSAttributedString, target: AnyObject, action: Selector) {
        self.init(frame: .zero)
        title = ""
        attributedTitle = label
        imagePosition = .noImage
        setup(target, action)
    }

    /// An icon card (block + inline actions): an SF symbol tinted to the body color.
    convenience init(symbol: String, target: AnyObject, action: Selector) {
        self.init(frame: .zero)
        title = ""
        image = symbolImage(symbol, pointSize: 15)
        contentTintColor = mallowText
        imagePosition = .imageOnly
        setup(target, action)
    }

    private func refresh() {
        layer?.backgroundColor = (hovering ? surfaceCardHover : surfaceCard).cgColor
        layer?.borderColor = (hovering ? borderStrong : mallowBorderColor).cgColor
    }

    override func hoverChanged() { refresh() }
}

/// Build the Text-Style popover for `c`. Buttons target the controller, so they operate on the text
/// view's preserved selection even while the popover is key. Transient → closes on outside click.
func makeStylePopover(_ c: EditorController) -> NSPopover {
    func label(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight,
               _ color: NSColor, strike: Bool = false, italic: Bool = false) -> NSAttributedString {
        var font = NSFont.systemFont(ofSize: size, weight: weight)
        if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        return NSAttributedString(string: s, attributes: attrs)
    }
    func sectionLabel(_ s: String) -> NSTextField {
        mallowLabel(s.uppercased(), size: 10, weight: .semibold, color: mallowFaint)
    }
    func row(_ buttons: [StyleButton]) -> NSStackView {
        let s = hstack(buttons, spacing: 6)
        s.distribution = .fillEqually
        return s
    }

    let title = mallowLabel(L.t("style.title"), size: 13, weight: .medium, color: mallowDim, align: .center)

    let headingRow = row([
        StyleButton(label: label("H1", 18, .bold, mallowText), target: c, action: #selector(EditorController.cmdH1(_:))),
        StyleButton(label: label("H2", 16, .bold, mallowText), target: c, action: #selector(EditorController.cmdH2(_:))),
        StyleButton(label: label("H3", 14, .bold, mallowText), target: c, action: #selector(EditorController.cmdH3(_:))),
        StyleButton(label: label(L.t("format.body"), 13, .medium, mallowDim), target: c, action: #selector(EditorController.cmdBody(_:))),
    ])
    let blockRow = row([
        StyleButton(symbol: "text.quote", target: c, action: #selector(EditorController.cmdQuote(_:))),
        StyleButton(symbol: "list.bullet", target: c, action: #selector(EditorController.cmdBullet(_:))),
        StyleButton(symbol: "list.number", target: c, action: #selector(EditorController.cmdNumbered(_:))),
        StyleButton(symbol: "chevron.left.forwardslash.chevron.right", target: c, action: #selector(EditorController.cmdCodeBlock(_:))),
        StyleButton(symbol: "minus", target: c, action: #selector(EditorController.cmdDivider(_:))),
    ])
    let inlineRow = row([
        StyleButton(label: label("B", 15, .bold, mallowText), target: c, action: #selector(EditorController.cmdBold(_:))),
        StyleButton(label: label("I", 15, .regular, mallowText, italic: true), target: c, action: #selector(EditorController.cmdItalic(_:))),
        StyleButton(label: label("S", 14, .regular, mallowText, strike: true), target: c, action: #selector(EditorController.cmdStrike(_:))),
        StyleButton(symbol: "curlybraces", target: c, action: #selector(EditorController.cmdCode(_:))),
    ])

    let stack = vstack([
        title,
        sectionLabel(L.t("style.headingSection")), headingRow,
        sectionLabel(L.t("style.blockSection")), blockRow,
        sectionLabel(L.t("style.inlineSection")), inlineRow,
    ], spacing: 7)
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.setCustomSpacing(12, after: title)

    let width: CGFloat = 248
    let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 300))
    root.addSubview(stack)
    NSLayoutConstraint.activate([
        stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
        stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
        stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
        stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
    ])
    // Rows + title span the full content width (so fillEqually distributes evenly).
    for v in [title, headingRow, blockRow, inlineRow] as [NSView] {
        v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    let vc = NSViewController()
    vc.view = root
    let pop = darkPopover(vc)
    pop.contentSize = NSSize(width: width, height: root.fittingSize.height)
    return pop
}
