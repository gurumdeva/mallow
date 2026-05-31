// StylePopoverPanel — the Text-Style popover (View), the native counterpart of the Tauri
// StylePopover.ts. The titlebar ✏️/Aa corner button opens it; it offers three labelled sections of
// rounded style cards — Heading (H1/H2/H3/Body), Block (quote/bullet/numbered/code/divider), and
// Inline (bold/italic/strikethrough/inline-code) — each wired to the EditorController's existing
// cmd* actions (which run the engine command on the current selection). This replaces the old
// `showStyleMenu` that popped the Format NSMenu by an `item(withTitle:"Format")` lookup — that lookup
// was always nil (the top-level item has no title), so the button did nothing.

import AppKit

/// Fixed size of a style card. All cards are square so the 4-button Heading/Inline rows and the
/// 5-button Block row are the same button size (the previous `.fillEqually` rows stretched each row's
/// buttons to a different width — the non-square bug this layout fixes).
private let styleCardSize: CGFloat = 44

/// A rounded "style card" button matching CSS `.style-btn`: surface-card fill, 1px border, radius 10,
/// hover → surface-card-hover + a stronger border — now a fixed 44×44 `SquareButton`. The shared
/// pieces of the `Config`; the two factories below fill in the symbol-vs-label content.
private func styleCard(_ content: SquareButton.Content) -> SquareButton.Config {
    SquareButton.Config(
        size: styleCardSize,
        cornerRadius: 10,
        content: content,
        fill: surfaceCard,
        hoverFill: surfaceCardHover,
        activeFill: nil,                 // no pressed state
        border: mallowBorderColor,
        hoverBorder: borderStrong,
        tint: mallowText,                // ignored for label content (label carries its own colors)
        hoverTint: mallowText)
}

/// A text card (H1/H2/H3/Body): the label is the button's attributed title (colors baked in).
func styleButton(label: NSAttributedString, target: AnyObject, action: Selector) -> SquareButton {
    SquareButton(styleCard(.label(label)), target: target, action: action)
}

/// An icon card (block + inline actions): an SF symbol tinted to the body color.
func styleButton(symbol: String, target: AnyObject, action: Selector) -> SquareButton {
    SquareButton(styleCard(.symbol(symbol, pointSize: 15)), target: target, action: action)
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
    // A row of fixed 44×44 cards, LEFT-aligned inside a full-width container. The buttons are their own
    // fixed size (no `.fillEqually`), so the 4-card Heading/Inline rows stay 44×44 just like the 5-card
    // Block row. Left-aligning (not centering) makes the first button of every row sit directly under
    // its section label (제목/블록/인라인 are leading-aligned) and under each other — a tidy column grid,
    // where centering left the shorter rows floating out of line with their labels. The widest row
    // (5 cards) sets the content width, so the 4-card rows simply leave a gap on the right.
    func row(_ buttons: [SquareButton]) -> NSView {
        let s = hstack(buttons, spacing: 6)
        s.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(s)
        NSLayoutConstraint.activate([
            s.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            s.topAnchor.constraint(equalTo: container.topAnchor),
            s.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            s.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
        ])
        return container
    }

    let title = mallowLabel(L.t("style.title"), size: 13, weight: .medium, color: mallowDim, align: .center)

    let headingRow = row([
        styleButton(label: label("H1", 18, .bold, mallowText), target: c, action: #selector(EditorController.cmdH1(_:))),
        styleButton(label: label("H2", 16, .bold, mallowText), target: c, action: #selector(EditorController.cmdH2(_:))),
        styleButton(label: label("H3", 14, .bold, mallowText), target: c, action: #selector(EditorController.cmdH3(_:))),
        styleButton(label: label(L.t("format.body"), 13, .medium, mallowDim), target: c, action: #selector(EditorController.cmdBody(_:))),
    ])
    let blockRow = row([
        styleButton(symbol: "text.quote", target: c, action: #selector(EditorController.cmdQuote(_:))),
        styleButton(symbol: "list.bullet", target: c, action: #selector(EditorController.cmdBullet(_:))),
        styleButton(symbol: "list.number", target: c, action: #selector(EditorController.cmdNumbered(_:))),
        styleButton(symbol: "chevron.left.forwardslash.chevron.right", target: c, action: #selector(EditorController.cmdCodeBlock(_:))),
        styleButton(symbol: "minus", target: c, action: #selector(EditorController.cmdDivider(_:))),
    ])
    let inlineRow = row([
        styleButton(label: label("B", 15, .bold, mallowText), target: c, action: #selector(EditorController.cmdBold(_:))),
        styleButton(label: label("I", 15, .regular, mallowText, italic: true), target: c, action: #selector(EditorController.cmdItalic(_:))),
        styleButton(label: label("S", 14, .regular, mallowText, strike: true), target: c, action: #selector(EditorController.cmdStrike(_:))),
        styleButton(symbol: "curlybraces", target: c, action: #selector(EditorController.cmdCode(_:))),
    ])

    let stack = vstack([
        title,
        sectionLabel(L.t("style.headingSection")), headingRow,
        sectionLabel(L.t("style.blockSection")), blockRow,
        sectionLabel(L.t("style.inlineSection")), inlineRow,
    ], spacing: 7)
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.setCustomSpacing(12, after: title)

    // Content width = the widest row (the 5-card Block row) + the 14px side insets. The Block row is
    // 5 cards of 44 with 4 gaps of 6 = 244; the card area drives the popover width, no fixed 248.
    let rowWidth = styleCardSize * 5 + 6 * 4
    let width = rowWidth + 14 * 2
    let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 300))
    root.addSubview(stack)
    NSLayoutConstraint.activate([
        stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
        stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
        stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
        stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
    ])
    // Title + each row container span the full content width: the title so its centered text fills the
    // card, the rows so their inner card group can center within it.
    for v in [title, headingRow, blockRow, inlineRow] as [NSView] {
        v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    let vc = NSViewController()
    vc.view = root
    let pop = darkPopover(vc)
    pop.contentSize = NSSize(width: width, height: root.fittingSize.height)
    return pop
}
