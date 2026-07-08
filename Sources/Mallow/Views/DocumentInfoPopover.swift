// DocumentInfoPopover — the SwiftUI face of the ⇧⌘I "Document Info" popover, mirroring the dormant
// Two tabs share one `.popover`: Statistics (a 2×2 grid of word / character /
// paragraph / read-time cards + an optional modified-date meta card) and Table of Contents (the
// document's headings; clicking a row moves the caret to that heading and scrolls it into view).
//
// This view OWNS no model layer of its own: the pure counting / heading-extraction logic is reused
// in Analysis/DocAnalysis.swift — `DocStats(markdown:)` and `DocOutline.extract(_:blocks:)` (with
// `OutlineItem`) are top-level there. Stats + outline are recomputed from `doc.textView.string` in the
// body each time the popover renders (cheap, and keeps the numbers in step with the live buffer; the
// buffer is never mutated — markdown stays the source of truth, the TOC only reads the engine parse).
// Colors come from the shared `Theme` tokens so light/dark stays in lockstep with the editor.

import SwiftUI
import AppKit

struct DocumentInfoPopover: View {
    /// The only stored property: the per-window document (its `textView` is the source text + the caret
    /// jump target; its `vm.filePath` gates the modified-date meta card). Everything else is derived.
    let doc: EditorDocument

    /// The two tabs. `Int`-backed so it binds directly to a segmented `Picker`.
    private enum Tab: Int { case statistics, contents }
    @State private var tab: Tab = .statistics

    /// Closes the popover after a TOC jump (the AppKit version called `popover.performClose`). Supplied
    /// by SwiftUI's `.popover` presentation — no extra stored property needed.
    @Environment(\.dismiss) private var dismiss

    /// Fixed content width (≈300; the 2×2 grid of ~132 cards + the 8px gap + 16px side insets).
    private let contentWidth: CGFloat = 300

    var body: some View {
        // Observe `revision` so Statistics + the TOC refresh LIVE while the popover stays open and the user
        // keeps typing (⇧⌘I then edit) — without this dependency the body reads only non-observable state
        // (textView.string / vm) and freezes at its open-time contents. (StatusBar reads revision the same
        // way.) A `let _` declaration, not a bare `_ =` expression, so the ViewBuilder doesn't treat it as a view.
        let _ = doc.revision
        // Recompute per render — cheap, and reflects the current buffer (mirrors the AppKit panel being
        // rebuilt on every open). `source` is read once and threaded through stats + outline.
        let source = doc.textView.string
        let stats = DocStats(markdown: bodyWithoutFrontmatter(source))  // count the body, not metadata
        let outline = DocOutline.extract(source, blocks: inkParseBlocks(source))

        VStack(spacing: 12) {
            // Centered title above the tabs (CSS `.stats-title`: 13 / medium / dim).
            Text(L.t("menu.documentInfo"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.dim)
                .frame(maxWidth: .infinity, alignment: .center)

            // The 2-segment tab switcher (통계 / 목차).
            Picker("", selection: $tab) {
                Text(L.t("info.tab.statistics")).tag(Tab.statistics)
                Text(L.t("info.tab.contents")).tag(Tab.contents)
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            // Swappable body. Each tab sizes itself; the popover follows via the surrounding VStack.
            switch tab {
            case .statistics: statisticsTab(stats)
            case .contents: contentsTab(outline)
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 8)
        .frame(width: contentWidth)
        .background(Theme.bg)
    }

    // MARK: - Statistics tab — a 2×2 grid of stat cards + an optional modified-date meta card.

    @ViewBuilder
    private func statisticsTab(_ stats: DocStats) -> some View {
        VStack(spacing: 8) {
            // 2×2 grid (matches `.stats-grid` / `.stat-card`: 24px value, 12px label, faint top-right icon).
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    statCard(value: "\(stats.words)",
                             label: L.t("info.stat.words"), symbol: "text.alignleft")
                    statCard(value: "\(stats.characters)",
                             label: L.t("info.stat.characters"), symbol: "character")
                }
                GridRow {
                    statCard(value: "\(stats.paragraphs)",
                             label: L.t("info.stat.paragraphs"), symbol: "paragraphsign")
                    // "1m" read-time = `${readMinutes}${minuteUnit}` (unit = "m").
                    statCard(value: "\(stats.readMinutes)\(L.t("info.readMinuteUnit"))",
                             label: L.t("info.stat.readTime"), symbol: "clock")
                }
            }

            // Modified-date meta card — only when the document has a file on disk (untitled docs have none).
            if let modified = modifiedDate {
                metaCard(value: Self.dateFormatter.string(from: modified),
                         label: L.t("info.meta.modified"), symbol: "calendar")
            }
        }
        .padding(.horizontal, 16)
    }

    /// On-disk modification date for the meta card (nil for an unsaved document → card omitted). Mirrors
    /// the AppKit `attributesOfItem(atPath:)[.modificationDate]` read.
    private var modifiedDate: Date? {
        doc.vm.filePath.flatMap {
            (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date
        }
    }

    /// Localized long-date + short-time for the meta card (e.g. "May 30, 2026 at 3:04 PM").
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .short
        return f
    }()

    /// One grid stat card: big value (24 / semibold) over a dim label (12), with a faint SF-symbol pinned
    /// top-right. Fixed ~72 height + the card surface, matching `.stat-card`.
    private func statCard(value: String, label: String, symbol: String) -> some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)   // huge counts shrink rather than clip the card
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(Theme.faint)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(height: 72)
        .frame(maxWidth: .infinity)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Full-width meta card: a vertically-centered value (14 / medium) + label (11 / dim) on the left,
    /// with the SF-symbol on the right. Same surface as the grid cards (`.stats-meta`).
    private func metaCard(value: String, label: String, symbol: String) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim)
            }
            Spacer(minLength: 8)
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(Theme.faint)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Table of Contents tab — a scrollable list of heading rows (indented by level).

    @ViewBuilder
    private func contentsTab(_ outline: [OutlineItem]) -> some View {
        if outline.isEmpty {
            // Empty state: a centered dim label, with a definite height so the popover sizes sanely.
            Text(L.t("info.toc.empty"))
                .font(.system(size: 12))
                .foregroundStyle(Theme.dim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .frame(height: 96)
                .padding(.horizontal, 16)
        } else {
            // Indent children relative to the shallowest heading present (matches the AppKit
            // `(level - minLevel)` indentation so a doc starting at H2 isn't pushed far right).
            let minLevel = outline.map(\.level).min() ?? 1
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    // `id: \.offset` — outline order is the stable identity (headings can repeat text).
                    ForEach(Array(outline.enumerated()), id: \.offset) { _, item in
                        TocRow(text: item.text,
                               indent: CGFloat(item.level - minLevel) * 14) { jump(to: item) }
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Cap the height so long outlines scroll instead of growing the popover unbounded; short
            // outlines stay compact (24px rows + 2px gaps + 8px padding), matching the AppKit min(…, 264).
            .frame(height: min(CGFloat(outline.count) * 24
                               + max(0, CGFloat(outline.count) - 1) * 2 + 8, 264))
        }
    }

    /// Move the caret to a heading and scroll it into view, then close the popover — the native
    /// counterpart of the Tauri `scrollToHeading` (selection-only; the buffer is untouched).
    private func jump(to item: OutlineItem) {
        let nsString = doc.textView.string as NSString
        let loc = max(0, min(item.caretUTF16, nsString.length))
        let r = NSRange(location: loc, length: 0)
        doc.textView.setSelectedRange(r)                        // also notifies the delegate (focus/typewriter)
        doc.textView.scrollRangeToVisible(r)
        doc.textView.window?.makeFirstResponder(doc.textView)   // return focus to the editor
        dismiss()                                               // minimal UI: close after jumping
    }
}

/// A left-aligned, borderless heading row that highlights on hover (so the list reads as clickable like
/// the Tauri `.toc-item`). `indent` shifts the title right by the heading's relative depth. The plain
/// button style strips SwiftUI's default chrome so only the hover fill shows.
private struct TocRow: View {
    let text: String
    let indent: CGFloat
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(text.isEmpty ? " " : text)   // never collapse an empty heading to zero height
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, 8 + indent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 24)
                .contentShape(Rectangle())     // whole row is the hit target, not just the glyphs
                .background(hovering ? Theme.weakOverlay : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
