// Theme — the Mallow color tokens, lifted verbatim from the Tauri app's src/style.css so the native
// chrome matches. Dark only for now (light theme is a follow-up).

import AppKit

let mallowBG = NSColor(srgbRed: 0x1c / 255, green: 0x1c / 255, blue: 0x1e / 255, alpha: 1)   // #1c1c1e
let mallowDim = NSColor(srgbRed: 0x98 / 255, green: 0x98 / 255, blue: 0x9d / 255, alpha: 1)  // #98989d
let mallowText = NSColor(srgbRed: 0xf2 / 255, green: 0xf2 / 255, blue: 0xf7 / 255, alpha: 1) // #f2f2f7
let mallowFaint = NSColor(srgbRed: 0x6d / 255, green: 0x6d / 255, blue: 0x72 / 255, alpha: 1) // #6d6d72 (--text-faint)
let mallowElevated = NSColor(srgbRed: 0x2c / 255, green: 0x2c / 255, blue: 0x2e / 255, alpha: 1) // #2c2c2e (--bg-elevated)

// Corner-button fills — the three interaction states from `.corner-btn` / :hover / :active in style.css.
let cornerBtnFill = NSColor(srgbRed: 60 / 255, green: 60 / 255, blue: 62 / 255, alpha: 0.55)        // rgba(60,60,62,.55)
let cornerBtnFillHover = NSColor(srgbRed: 80 / 255, green: 80 / 255, blue: 82 / 255, alpha: 0.7)    // rgba(80,80,82,.7)
let cornerBtnFillActive = NSColor(srgbRed: 96 / 255, green: 96 / 255, blue: 98 / 255, alpha: 0.8)   // rgba(96,96,98,.8)

// Card surface behind stat cards / style buttons (--surface-card) + the tabs track (--overlay-tabs-track).
let surfaceCard = NSColor(srgbRed: 72 / 255, green: 72 / 255, blue: 74 / 255, alpha: 0.45)          // rgba(72,72,74,.45)
let surfaceCardHover = NSColor(srgbRed: 96 / 255, green: 96 / 255, blue: 98 / 255, alpha: 0.6)      // --surface-card-hover
let borderStrong = NSColor(white: 1, alpha: 0.18)                                                   // --border-strong (style-btn hover)
let overlayTabsTrack = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.25)                          // rgba(0,0,0,.25)
let overlayWeak = NSColor(white: 1, alpha: 0.05)                                                    // --overlay-weak (toc hover)
let mallowBorderColor = NSColor(white: 1, alpha: 0.08)                                              // --border (hr rule, card borders)

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
