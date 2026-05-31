// StylePopover — the SwiftUI "Text Style" popover content, shown inside a `.popover` opened from the
// titlebar Aa corner button. It offers three labelled sections of rounded 44×44 style cards —
// Heading (H1/H2/H3/Body), Block (quote/bullet/numbered/code/divider), and Inline
// (bold/italic/strikethrough/inline-code) — each wired through `EditorDocument.vm` to the engine's
// existing commands (which run on the current selection).
//
// This mirrors the dormant AppKit version in StylePopoverPanel.swift — same buttons, sections, icons,
// sizes, and the deliberate left-aligned-rows layout — but is written as idiomatic SwiftUI rather than
// a port of the AutoLayout/NSPopover code. The popover chrome (background, arrow) is provided by the
// host `.popover`, so this view only lays out its content.

import SwiftUI

struct StylePopover: View {
    /// The document whose view-model receives the style commands. Buttons call through `doc.vm` so they
    /// operate on the editor's current selection.
    let doc: EditorDocument

    /// Side inset around the content. Matches the AppKit version's 14px root insets.
    private let pad: CGFloat = 14
    /// Spacing between the section-label-and-row pairs (matches the AppKit vstack spacing of 7).
    private let sectionGap: CGFloat = 7
    /// Horizontal gap between cards in a row (matches the AppKit hstack spacing of 6).
    private let cardGap: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: sectionGap) {
            // Centered title — spans the full content width so its text centers over the card grid.
            Text(L.t("style.title"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.dim)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 12 - sectionGap)   // total ≈12pt below the title, as in the AppKit panel

            // Heading: H1 / H2 / H3 / Body → applyHeading(1/2/3/0).
            section(L.t("style.headingSection")) {
                card { headingLabel("H1", size: 18, weight: .bold, color: Theme.text) }
                    action: { doc.vm.applyHeading(1) }
                card { headingLabel("H2", size: 16, weight: .bold, color: Theme.text) }
                    action: { doc.vm.applyHeading(2) }
                card { headingLabel("H3", size: 14, weight: .bold, color: Theme.text) }
                    action: { doc.vm.applyHeading(3) }
                card { headingLabel(L.t("format.body"), size: 13, weight: .medium, color: Theme.dim) }
                    action: { doc.vm.applyHeading(0) }
            }

            // Block: quote / bullet / numbered / code-block / divider (SF Symbols).
            section(L.t("style.blockSection")) {
                card { symbol("text.quote") }
                    action: { doc.vm.apply("toggle_blockquote") }
                card { symbol("list.bullet") }
                    action: { doc.vm.apply("toggle_bullet_list") }
                card { symbol("list.number") }
                    action: { doc.vm.apply("toggle_ordered_list") }
                card { symbol("chevron.left.forwardslash.chevron.right") }
                    action: { doc.vm.apply("toggle_code_block") }
                card { symbol("minus") }
                    action: { doc.vm.apply("insert_divider") }
            }

            // Inline: bold / italic / strikethrough / inline-code.
            section(L.t("style.inlineSection")) {
                card { inlineLabel("B", size: 15, weight: .bold) }
                    action: { doc.vm.apply("toggle_strong") }
                card { inlineLabel("I", size: 15, weight: .regular).italic() }
                    action: { doc.vm.apply("toggle_emphasis") }
                card { inlineLabel("S", size: 14, weight: .regular).strikethrough() }
                    action: { doc.vm.apply("toggle_strikethrough") }
                card { symbol("curlybraces") }
                    action: { doc.vm.apply("toggle_inline_code") }
            }
        }
        .padding(pad)
        // Content width is driven by the widest row (the 5-card Block row): 5×44 + 4×6 gaps, plus the
        // side insets — so the 4-card Heading/Inline rows simply leave a gap on the right rather than
        // stretching or centering their cards. `fixedSize` lets the popover size to this content.
        .frame(width: 44 * 5 + cardGap * 4 + pad * 2)
        .fixedSize()
    }

    // MARK: - Building blocks

    /// One section: an uppercase, leading-aligned label above a LEFT-aligned row of square cards.
    /// Left-aligning (not centering) makes the first card of every row sit directly under its section
    /// label and under the other rows' first card — a tidy column grid. The `@ViewBuilder` cards become
    /// an HStack; shorter rows leave space on the right of the (Block-row-driven) content width.
    @ViewBuilder
    private func section<Cards: View>(_ title: String,
                                      @ViewBuilder cards: () -> Cards) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.faint)
            .frame(maxWidth: .infinity, alignment: .leading)
        HStack(spacing: cardGap) {
            cards()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A single 44×44 style-card button: the supplied label content over the shared surface-card style.
    private func card<Label: View>(@ViewBuilder _ label: () -> Label,
                                   action: @escaping () -> Void) -> some View {
        Button(action: action, label: label)
            .buttonStyle(SquareButtonStyle.styleCard)
    }

    // MARK: - Card content

    /// SF-symbol card content (block + inline-code actions), tinted to the body text color, ~15pt.
    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 15))
            .foregroundStyle(Theme.text)
    }

    /// Heading-card text content (H1/H2/H3/Body): carries its own size/weight/color.
    private func headingLabel(_ text: String, size: CGFloat,
                              weight: Font.Weight, color: Color) -> some View {
        Text(text)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(color)
    }

    /// Inline-card text content (B/I/S): always body-colored; italic/strikethrough are applied by the
    /// caller as view modifiers so they compose with this `Text`.
    private func inlineLabel(_ text: String, size: CGFloat, weight: Font.Weight) -> Text {
        Text(text)
            .font(.system(size: size, weight: weight))
            .foregroundColor(Theme.text)
    }
}
