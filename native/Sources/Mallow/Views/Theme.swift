// Theme — the Mallow color tokens, lifted verbatim from the Tauri app's src/style.css so the native
// chrome matches. Each token is a DYNAMIC NSColor that resolves per appearance: on a dark system it
// returns the original literal (byte-identical to the old dark-only build), on a light system it
// returns the light value from style.css `:root[data-theme="light"]`. The window/popovers follow the
// system appearance, so the chrome flips automatically when macOS does.

import AppKit

/// Build a dynamic color: `dark` on `.darkAqua`, `light` otherwise. `bestMatch` collapses any of the
/// many concrete appearances (vibrant variants, high-contrast, etc.) down to aqua vs. darkAqua first,
/// so this resolves correctly under every real appearance — not just the two base names.
private func dynamicColor(dark: NSColor, light: NSColor) -> NSColor {
    NSColor(name: nil) { ap in
        ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    }
}

let mallowBG = dynamicColor(
    dark: NSColor(srgbRed: 0x1c / 255, green: 0x1c / 255, blue: 0x1e / 255, alpha: 1),   // #1c1c1e
    light: NSColor(srgbRed: 0xff / 255, green: 0xff / 255, blue: 0xff / 255, alpha: 1))  // #ffffff
let mallowDim = dynamicColor(
    dark: NSColor(srgbRed: 0x98 / 255, green: 0x98 / 255, blue: 0x9d / 255, alpha: 1),   // #98989d
    light: NSColor(srgbRed: 0x6b / 255, green: 0x6b / 255, blue: 0x70 / 255, alpha: 1))  // #6b6b70
let mallowText = dynamicColor(
    dark: NSColor(srgbRed: 0xf2 / 255, green: 0xf2 / 255, blue: 0xf7 / 255, alpha: 1),   // #f2f2f7
    light: NSColor(srgbRed: 0x1c / 255, green: 0x1c / 255, blue: 0x1e / 255, alpha: 1))  // #1c1c1e
let mallowFaint = dynamicColor(
    dark: NSColor(srgbRed: 0x6d / 255, green: 0x6d / 255, blue: 0x72 / 255, alpha: 1),   // #6d6d72 (--text-faint)
    light: NSColor(srgbRed: 0x9b / 255, green: 0x9b / 255, blue: 0xa0 / 255, alpha: 1))  // #9b9ba0
let mallowElevated = dynamicColor(
    dark: NSColor(srgbRed: 0x2c / 255, green: 0x2c / 255, blue: 0x2e / 255, alpha: 1),   // #2c2c2e (--bg-elevated)
    light: NSColor(srgbRed: 0xf0 / 255, green: 0xf0 / 255, blue: 0xf2 / 255, alpha: 1))  // #f0f0f2

// Corner-button fills — the three interaction states from `.corner-btn` / :hover / :active in style.css.
let cornerBtnFill = dynamicColor(
    dark: NSColor(srgbRed: 60 / 255, green: 60 / 255, blue: 62 / 255, alpha: 0.55),      // rgba(60,60,62,.55)
    light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.05))                          // rgba(0,0,0,.05)
let cornerBtnFillHover = dynamicColor(
    dark: NSColor(srgbRed: 80 / 255, green: 80 / 255, blue: 82 / 255, alpha: 0.7),       // rgba(80,80,82,.7)
    light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.09))                          // rgba(0,0,0,.09)
let cornerBtnFillActive = dynamicColor(
    dark: NSColor(srgbRed: 96 / 255, green: 96 / 255, blue: 98 / 255, alpha: 0.8),       // rgba(96,96,98,.8)
    light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.12))                          // rgba(0,0,0,.12)

// Card surface behind stat cards / style buttons (--surface-card) + the tabs track (--overlay-tabs-track).
let surfaceCard = dynamicColor(
    dark: NSColor(srgbRed: 72 / 255, green: 72 / 255, blue: 74 / 255, alpha: 0.45),      // rgba(72,72,74,.45)
    light: NSColor(srgbRed: 0xe8 / 255, green: 0xe8 / 255, blue: 0xec / 255, alpha: 1))  // #e8e8ec
let surfaceCardHover = dynamicColor(
    dark: NSColor(srgbRed: 96 / 255, green: 96 / 255, blue: 98 / 255, alpha: 0.6),       // --surface-card-hover
    light: NSColor(srgbRed: 0xdd / 255, green: 0xdd / 255, blue: 0xe2 / 255, alpha: 1))  // #dddde2
let borderStrong = dynamicColor(
    dark: NSColor(white: 1, alpha: 0.18),                                                // --border-strong (style-btn hover)
    light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.18))                          // rgba(0,0,0,.18)
let overlayTabsTrack = dynamicColor(
    dark: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.25),                           // rgba(0,0,0,.25)
    light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.06))                          // rgba(0,0,0,.06)
let overlayWeak = dynamicColor(
    dark: NSColor(white: 1, alpha: 0.05),                                                // --overlay-weak (toc hover)
    light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.05))                          // rgba(0,0,0,.05)
let mallowBorderColor = dynamicColor(
    dark: NSColor(white: 1, alpha: 0.08),                                                // --border (hr rule, card borders)
    light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.1))                           // rgba(0,0,0,.1)

/// Body line spacing matching the Tauri app's `line-height: 1.8`. NSLayoutManager multiplies the
/// font's natural line height (~1.2× for SF Pro) by this multiple, so ~1.5 lands at roughly 1.8×
/// font-size across both body and headings — the airy rhythm the WebView version has. Applied as the
/// base paragraph style in restyle() and as the text view's default/typing style so typed text matches.
let mallowBodyParagraphStyle: NSParagraphStyle = {
    let p = NSMutableParagraphStyle()
    p.lineHeightMultiple = 1.5
    return p
}()

/// Blockquote indent (CSS `.ProseMirror blockquote { padding-left:16; border-left:3px }`): the body
/// rhythm plus a left inset, leaving a gutter for the 3px quote bar drawn by MarkdownTextView.
let mallowQuoteParagraphStyle: NSParagraphStyle = {
    let p = NSMutableParagraphStyle()
    p.lineHeightMultiple = 1.5
    p.firstLineHeadIndent = 22
    p.headIndent = 22
    return p
}()

/// Code-block indent: a small left inset so fenced code sits off the margin inside its tint.
let mallowCodeParagraphStyle: NSParagraphStyle = {
    let p = NSMutableParagraphStyle()
    p.lineHeightMultiple = 1.4
    p.firstLineHeadIndent = 12
    p.headIndent = 12
    return p
}()
