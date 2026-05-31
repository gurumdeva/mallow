// UIComponents — the shared AppKit view-construction factories. Several popovers/panels in the chrome
// hand-rolled the IDENTICAL boilerplate to build a dark transient popover, a styled NSTextField label,
// a stacked container, an SF-symbol image, a rounded stat card, and a sheet-or-modal alert. This
// collapses that repetition to one place so the call sites read as intent, not assembly. These are
// pure construction helpers: every factory reproduces the EXACT attributes (font/size/weight/color/
// alignment/spacing/radius/inset/behavior) of the sites it replaces — it does not restyle anything.
// (The HoverButton base — SquareButton/FilenameButton/TocRowButton — is its own seam.)

import AppKit

// MARK: - Transient popover

/// Apply Mallow's popover chrome — `.transient` (closes on outside click) — to an existing popover. No
/// forced appearance: the popover follows the system, and its content uses the dynamic Theme tokens, so
/// it adapts light/dark to match. Split out from `darkPopover` for the info popover, whose content view-
/// controller holds a back-reference to the popover and so must be built before this is applied.
func configureTransient(_ p: NSPopover) {
    p.behavior = .transient
}

/// A `.transient` NSPopover hosting `vc` — the shared shell behind the Text-Style, document-info, and
/// rename popovers (each previously built these same lines by hand). It follows the system appearance;
/// its content's dynamic tokens do the light/dark work. Callers still set `contentSize` and call
/// `show(relativeTo:…)` themselves, since those vary per anchor.
func darkPopover(_ vc: NSViewController) -> NSPopover {
    let p = NSPopover()
    p.contentViewController = vc
    configureTransient(p)
    return p
}

// MARK: - Styled label

/// A non-editable NSTextField label with Mallow's standard styling knobs in one call. Mirrors the
/// hand-built `NSTextField(labelWithString:)` + font/color/alignment used across InfoPanel,
/// StylePopoverPanel, and ChromeBar. `lineBreak` is applied only when supplied (so labels that didn't
/// set one keep AppKit's default), and `align` defaults to the AppKit-default leading alignment.
func mallowLabel(_ string: String,
                 size: CGFloat,
                 weight: NSFont.Weight = .regular,
                 color: NSColor,
                 align: NSTextAlignment = .left,
                 lineBreak: NSLineBreakMode? = nil) -> NSTextField {
    let l = NSTextField(labelWithString: string)
    l.font = NSFont.systemFont(ofSize: size, weight: weight)
    l.textColor = color
    l.alignment = align
    if let lineBreak = lineBreak { l.lineBreakMode = lineBreak }
    return l
}

// MARK: - Stack helpers

/// A vertical NSStackView. `spacing` + `alignment` cover the common cases; any extra knobs
/// (distribution, edgeInsets, custom spacing) are set by the caller afterward so nothing layout-
/// affecting is hidden. Default alignment matches the leading edge the call sites used.
func vstack(_ views: [NSView],
            spacing: CGFloat = 0,
            alignment: NSLayoutConstraint.Attribute = .leading) -> NSStackView {
    let s = NSStackView(views: views)
    s.orientation = .vertical
    s.spacing = spacing
    s.alignment = alignment
    return s
}

/// A horizontal NSStackView. Like `vstack`, only orientation/spacing/alignment are set here; the
/// caller sets `distribution` (e.g. `.fillEqually`) where it needs one. The default alignment is
/// `.centerY` — the valid cross-axis attribute for a HORIZONTAL stack (NSStackView's own default);
/// `.leading` is a vertical-stack attribute and silently breaks a horizontal stack into a column.
func hstack(_ views: [NSView],
            spacing: CGFloat = 0,
            alignment: NSLayoutConstraint.Attribute = .centerY) -> NSStackView {
    let s = NSStackView(views: views)
    s.orientation = .horizontal
    s.spacing = spacing
    s.alignment = alignment
    return s
}

// MARK: - SF-symbol image

/// An SF-Symbol image at a given point size + weight, or nil if the symbol is unavailable — the exact
/// `NSImage(systemSymbolName:…)?.withSymbolConfiguration(…)` used by the corner/style buttons and the
/// info-panel icons. The caller still owns tint (`contentTintColor`), which varies per site.
func symbolImage(_ name: String,
                 pointSize: CGFloat,
                 weight: NSFont.Weight = .regular) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight))
}

// MARK: - Rounded card + stat card

/// Wrap a content view in a rounded surface-card box (NSBox does the fill + radius cleanly), matching
/// the reference's `--surface-card` fill, 12px radius, and 14×12 inner padding. A non-positive
/// `minHeight` skips the height floor (used by the meta row, which sizes to its content).
func cardBox(_ content: NSView, minHeight: CGFloat) -> NSBox {
    let box = NSBox()
    box.boxType = .custom
    box.titlePosition = .noTitle
    box.fillColor = surfaceCard
    box.borderWidth = 0
    box.cornerRadius = 12
    box.contentViewMargins = NSSize(width: 14, height: 12)
    content.translatesAutoresizingMaskIntoConstraints = false
    box.contentView = content
    if minHeight > 0 {
        box.heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight).isActive = true
    }
    return box
}

/// A rounded stat card: a big `value` over a dim `label`, with a faint SF-symbol pinned top-right —
/// the shared builder behind both the info-panel 2×2 stat grid and its single modified-date meta row
/// (the audit flagged these as near-duplicates). The two differ only in their fonts and vertical
/// row alignment, which are parameters: the grid uses 24/600 value · 12 label · `.top`; the meta row
/// uses 14/500 value · 11 label · `.centerY`. Fill / radius / inset come from `cardBox`, so the
/// surface, 12px radius, and 14×12 padding stay identical across both.
func statCard(value: String,
              label: String,
              symbol: String,
              valueFont: NSFont,
              labelFont: NSFont,
              rowAlignment: NSLayoutConstraint.Attribute,
              minHeight: CGFloat) -> NSBox {
    let valueLabel = NSTextField(labelWithString: value)
    valueLabel.font = valueFont
    valueLabel.textColor = mallowText
    valueLabel.lineBreakMode = .byTruncatingTail
    let nameLabel = NSTextField(labelWithString: label)
    nameLabel.font = labelFont
    nameLabel.textColor = mallowDim
    let main = vstack([valueLabel, nameLabel], spacing: 2)

    let icon = NSImageView()
    icon.image = symbolImage(symbol, pointSize: 12)
    icon.contentTintColor = mallowFaint
    icon.setContentHuggingPriority(.required, for: .horizontal)

    let spacer = NSView()
    let row = hstack([main, spacer, icon], alignment: rowAlignment)
    return cardBox(row, minHeight: minHeight)
}

// MARK: - Alert presentation

/// Present an alert as a sheet on `window` when one exists, else as an app-modal dialog — the exact
/// `if let window { beginSheetModal } else { runModal }` fallback duplicated by the rename- and
/// image-error paths. Alert contents are the caller's; this only chooses the presentation.
func presentAlert(_ alert: NSAlert, on window: NSWindow?) {
    if let window = window {
        alert.beginSheetModal(for: window, completionHandler: nil)
    } else {
        alert.runModal()
    }
}
