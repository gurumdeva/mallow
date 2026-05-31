// InfoPanel — the ⇧⌘I document-info popover (View + a small Model layer), the native counterpart of
// the Tauri app's InfoPopover. Two tabs share one NSPopover: Statistics (words / characters /
// paragraphs / read time) and Table of Contents (the document's headings; click to scroll + move the
// caret to that heading). An NSSegmentedControl switches tabs.
//
// MVVM seam: counting and heading extraction are pure logic, kept off the controller in `DocStats`
// and `DocOutline` (Model). The controller only opens the popover and performs the caret jump (a
// view/selection action, like the Tauri EditorController.scrollToHeading). The buffer is never
// mutated — markdown stays the source of truth; the TOC only reads the engine's parse.

import AppKit

// MARK: - Statistics (pure logic, mirrors the Tauri StatsCalculator)

/// Word / character / paragraph counts + a ~200 wpm read-time estimate for a markdown string.
/// Pure value type — no editor/engine dependency — so the numbers are testable in isolation.
struct DocStats {
    let words: Int
    let characters: Int
    let paragraphs: Int
    let readMinutes: Int

    init(markdown: String) {
        // Strip embedded images before counting (matches the reference): a pasted image's base64
        // data URI is a single enormous "word" that would wildly inflate characters + read time and
        // make an image-only line count as a prose paragraph. Newlines are preserved so paragraph
        // structure stays intact. Four passes: inline images, reference-style image uses, link/image
        // reference definitions, and a safety net for any leftover long data: token.
        var stripped = markdown
        for pattern in [
            #"!\[[^\]]*\]\(([^()]*(?:\([^()]*\)[^()]*)*)\)"#,   // ![alt](url) (1-level nested parens)
            #"!\[[^\]]*\]\[[^\]]*\]"#,                          // ![alt][id]
            #"(?m)^[ \t]{0,3}\[[^\]]+\]:[ \t]*\S.*$"#,          // [id]: url …  (definition line)
            #"data:[^\s)\]]{100,}"#,                            // leftover long data: URI (100+ chars)
        ] {
            stripped = stripped.replacingOccurrences(of: pattern, with: "",
                                                     options: .regularExpression)
        }

        let text = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        let chars = text.count
        guard chars > 0 else {
            words = 0; characters = 0; paragraphs = 0; readMinutes = 0
            return
        }

        characters = chars
        words = DocStats.countWords(text)
        paragraphs = DocStats.countParagraphs(stripped)
        // Latin-script read time is word-based at 200 wpm (the brief's target). Always at least 1m
        // for any non-empty document. CJK localization (500 chars/min) is a later follow-up.
        readMinutes = max(1, Int((Double(words) / 200.0).rounded(.up)))
    }

    /// Word count by whitespace splitting. AppKit has no Intl.Segmenter; this matches the Tauri
    /// fallback path (`text.split(/\s+/).filter(Boolean)`). CJK dictionary segmentation is a later
    /// follow-up (the reference also degrades to this split where Segmenter is unavailable).
    private static func countWords(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// Prose-paragraph count: blank-line-separated blocks that contain at least one non-structural
    /// (prose) line. Headings, list items, code fences, rules, and quotes are NOT paragraphs —
    /// mirrors the reference `countParagraphs`.
    private static func countParagraphs(_ markdown: String) -> Int {
        // Drop fenced code blocks so code lines never count as prose.
        let withoutCode = markdown.replacingOccurrences(
            of: #"```[\s\S]*?```"#, with: "\n\n", options: .regularExpression)
        var count = 0
        // Split on blank lines (≥2 newlines), then count any block that has a prose (non-structural)
        // line. Equivalent for-loop of the JS `.split(/\n{2,}/).filter(...).some(...)`.
        for block in splitBlankLineBlocks(withoutCode) {
            let lines = block.split(separator: "\n").map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if lines.isEmpty { continue }                 // whitespace-only block
            if lines.contains(where: { !isStructuralLine($0) }) { count += 1 }
        }
        return count
    }

    /// Split text into blocks separated by one-or-more blank lines (≥2 newlines), matching
    /// JS `split(/\n{2,}/)`. Implemented directly (Foundation regex split is awkward for groups).
    private static func splitBlankLineBlocks(_ s: String) -> [String] {
        var blocks: [String] = []
        var current = ""
        var newlineRun = 0
        for ch in s {
            if ch == "\n" {
                newlineRun += 1
                if newlineRun >= 2 {
                    // A blank line ends the current block; collapse the rest of the run.
                    if newlineRun == 2, !current.isEmpty { blocks.append(current); current = "" }
                    continue
                }
                current.append(ch)
            } else {
                newlineRun = 0
                current.append(ch)
            }
        }
        if !current.isEmpty { blocks.append(current) }
        return blocks
    }

    /// A non-prose structural line: ATX heading / thematic break / list item / blockquote.
    private static func isStructuralLine(_ line: String) -> Bool {
        let s = line.trimmingCharacters(in: .whitespaces)
        func m(_ pattern: String) -> Bool {
            s.range(of: pattern, options: .regularExpression) != nil
        }
        return m(#"^#{1,6}\s"#)                  // heading
            || m(#"^(-{3,}|\*{3,}|_{3,})$"#)     // thematic break (hr)
            || m(#"^([-*+]|\d+[.)])\s"#)         // list item
            || m(#"^>"#)                         // blockquote
    }
}

// MARK: - Table of Contents (heading extraction off the engine parse)

/// One outline entry: the rendered heading text, its level, and the UTF-16 caret target in the
/// buffer (the start of the heading's text, mirroring the reference caret placement).
struct OutlineItem {
    let text: String
    let level: Int
    let caretUTF16: Int   // where to put the caret + scroll when this row is clicked
}

/// Extracts the document outline from the engine parse. Heading blocks carry their full source span
/// (including the `#` markers); the heading's inline runs carry the rendered text, so concatenating
/// those substrings gives the same clean text the WebView's `el.textContent` shows (no `#`/leading
/// space). The caret target is the first inline run's start (or the block start if a heading has no
/// inlines, e.g. an empty `##`).
enum DocOutline {
    static func extract(_ source: String, blocks: [PBlock]) -> [OutlineItem] {
        let ns = source as NSString
        let nsLen = ns.length
        var items: [OutlineItem] = []
        for block in blocks where block.kindTag == "Heading" {
            let level = block.headingLevel ?? 1

            // Concatenate the inline-run substrings → rendered heading text (markers excluded).
            var text = ""
            for inline in block.inlines {
                let lo = byteToUTF16(source, inline.range.start)
                let hi = min(byteToUTF16(source, inline.range.end), nsLen)
                if hi > lo { text += ns.substring(with: NSRange(location: lo, length: hi - lo)) }
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)

            // Fallback for headings with no inline runs (empty heading): strip the leading `#`s and
            // spaces off the block's own source so the row still shows *something* sensible.
            if text.isEmpty {
                let bLo = byteToUTF16(source, block.range.start)
                let bHi = min(byteToUTF16(source, block.range.end), nsLen)
                if bHi > bLo {
                    let raw = ns.substring(with: NSRange(location: bLo, length: bHi - bLo))
                    text = raw.drop { $0 == "#" || $0 == " " || $0 == "\t" }
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            // Caret target: the first inline run's start (heading text start), else the block start.
            let caret = block.inlines.first.map { byteToUTF16(source, $0.range.start) }
                ?? byteToUTF16(source, block.range.start)
            items.append(OutlineItem(text: text, level: level, caretUTF16: min(caret, nsLen)))
        }
        return items
    }
}

// MARK: - The popover view-controller

/// The popover's content: a segmented tab switcher over a swappable body. Rebuilt each time it's
/// shown so the numbers + headings reflect the current buffer (the popover is `.transient`, so a new
/// instance is created per open — no long-lived caching needed). Heading clicks are forwarded to the
/// owning EditorController via a closure (the controller performs the caret jump on the responder).
final class InfoPanelViewController: NSViewController {
    private let stats: DocStats
    private let outline: [OutlineItem]
    private let modified: Date?
    private let onJump: (OutlineItem) -> Void
    private weak var popover: NSPopover?

    private let tabs = NSSegmentedControl(
        labels: [L.t("info.tab.statistics"), L.t("info.tab.contents")],
        trackingMode: .selectOne, target: nil, action: nil)
    private let bodyContainer = NSView()

    /// Fixed content width (the 2×2 grid + 16px side insets). Height is NOT fixed — it follows the
    /// current tab's content via `preferredContentSize` so the popover never squeezes the body.
    private let rootWidth: CGFloat = 304

    init(stats: DocStats, outline: [OutlineItem], modified: Date?, popover: NSPopover,
         onJump: @escaping (OutlineItem) -> Void) {
        self.stats = stats
        self.outline = outline
        self.modified = modified
        self.popover = popover
        self.onJump = onJump
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("InfoPanelViewController is created in code") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: rootWidth, height: 314))

        // Centered title above the tabs (CSS `.stats-title`: 13/medium/dim), matching the reference.
        let titleLabel = mallowLabel(L.t("menu.documentInfo"), size: 13, weight: .medium,
                                     color: mallowDim, align: .center)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(titleLabel)

        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.selectedSegment = 0
        tabs.target = self
        tabs.action = #selector(tabChanged(_:))
        tabs.segmentDistribution = .fillEqually
        root.addSubview(tabs)

        bodyContainer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bodyContainer)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            titleLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            tabs.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            tabs.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            tabs.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            bodyContainer.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 12),
            bodyContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bodyContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bodyContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])
        self.view = root
        showBody(statsBody())
    }

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        showBody(sender.selectedSegment == 0 ? statsBody() : tocBody())
    }

    private func showBody(_ v: NSView) {
        bodyContainer.subviews.forEach { $0.removeFromSuperview() }
        v.translatesAutoresizingMaskIntoConstraints = false
        bodyContainer.addSubview(v)
        // Pin top/leading/trailing required; the bottom pin is high-but-not-required so it can never
        // fight the body's own required content height — it just lets the body fill if the container is
        // taller. This keeps `fittingSize` (below) equal to the true content height, so the popover is
        // sized to fit exactly instead of compressing the stack (which made the meta row overlap).
        let bottom = v.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor)
        bottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
            v.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
            bottom,
        ])
        // Grow the popover to the current tab's natural height. With a fixed-height frame the stats
        // body (2×2 grid + meta row) was taller than the popover, so NSStackView compressed it and the
        // meta row overlapped the bottom cards (no AutoLayout conflict is logged — the stack's spacing
        // constraints are sub-required, so it overlaps under compression rather than erroring). Sizing
        // to the content's fittingSize gives each tab exactly the height it needs.
        view.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: rootWidth, height: ceil(view.fittingSize.height))
    }

    // MARK: Statistics body — a 2×2 grid of rounded stat cards + a modified-date meta row, matching
    // the reference `.stats-grid` / `.stat-card` / `.stats-meta` (24px value, 12px label, faint icon).

    /// Localized long-date + short-time for the meta row (Intl-equivalent: "May 30, 2026 at 3:04 PM").
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .short
        return f
    }()

    private func statsBody() -> NSView {
        let cardWidth: CGFloat = 132   // (304 − 32 insets − 8 gap) / 2

        // One stat card: a big value (24/semibold) over a dim label (12), with a faint SF-symbol
        // top-right. The shared statCard builder owns the surface/radius/inset; the grid pins an EXACT
        // width AND height. A fixed height (not `>=`) is what keeps the layout unambiguous: with only a
        // minimum, `fittingSize` collapsed the cards and the popover came out too short, so the stack
        // compressed and the meta row overlapped the bottom cards.
        let cardHeight: CGFloat = 78
        func card(_ value: String, _ label: String, _ symbol: String) -> NSView {
            let box = statCard(value: value, label: label, symbol: symbol,
                               valueFont: NSFont.systemFont(ofSize: 24, weight: .semibold),
                               labelFont: NSFont.systemFont(ofSize: 12),
                               rowAlignment: .top, minHeight: 0)
            NSLayoutConstraint.activate([
                box.widthAnchor.constraint(equalToConstant: cardWidth),
                box.heightAnchor.constraint(equalToConstant: cardHeight),
            ])
            return box
        }
        func hrow(_ a: NSView, _ b: NSView) -> NSStackView {
            hstack([a, b], spacing: 8)
        }
        // "1m" read-time format matches the reference's `${readMinutes}${minuteUnit}` (unit = "m").
        let grid = vstack([
            hrow(card("\(stats.words)", L.t("info.stat.words"), "text.alignleft"),
                 card("\(stats.characters)", L.t("info.stat.characters"), "character")),
            hrow(card("\(stats.paragraphs)", L.t("info.stat.paragraphs"), "paragraphsign"),
                 card("\(stats.readMinutes)\(L.t("info.readMinuteUnit"))", L.t("info.stat.readTime"), "clock")),
        ], spacing: 8)

        let outer = vstack([grid], spacing: 8)
        outer.edgeInsets = NSEdgeInsets(top: 2, left: 16, bottom: 8, right: 16)

        // Modified-date meta row — only when the document has a file on disk (untitled docs have none).
        // Same statCard builder as the grid, just with the meta fonts (14/500 value, 11 label) and a
        // vertically-centered row; no min-height (it sizes to its content) and a full-width pin.
        if let modified = modified {
            let meta = statCard(value: Self.dateFormatter.string(from: modified),
                                label: L.t("info.meta.modified"), symbol: "calendar",
                                valueFont: NSFont.systemFont(ofSize: 14, weight: .medium),
                                labelFont: NSFont.systemFont(ofSize: 11),
                                rowAlignment: .centerY, minHeight: 0)
            NSLayoutConstraint.activate([
                meta.widthAnchor.constraint(equalToConstant: cardWidth * 2 + 8),
                meta.heightAnchor.constraint(equalToConstant: 56),   // fixed, like the grid cards
            ])
            outer.addArrangedSubview(meta)
        }
        return outer
    }

    // MARK: Table-of-Contents body — a scrollable list of heading buttons (indented by level).

    private func tocBody() -> NSView {
        guard !outline.isEmpty else {
            let empty = mallowLabel(L.t("info.toc.empty"), size: 12, color: mallowDim, align: .center)
            let wrap = NSView()
            empty.translatesAutoresizingMaskIntoConstraints = false
            wrap.addSubview(empty)
            NSLayoutConstraint.activate([
                empty.centerXAnchor.constraint(equalTo: wrap.centerXAnchor),
                empty.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
                empty.leadingAnchor.constraint(greaterThanOrEqualTo: wrap.leadingAnchor, constant: 16),
                wrap.heightAnchor.constraint(equalToConstant: 96),   // definite height so the popover sizes sanely
            ])
            return wrap
        }

        // Indent children relative to the shallowest heading present (matches the reference's
        // `(level - minLevel)` indentation so a doc starting at H2 isn't pushed far right).
        let minLevel = outline.map(\.level).min() ?? 1

        let list = vstack([], spacing: 2)
        list.translatesAutoresizingMaskIntoConstraints = false
        for (idx, item) in outline.enumerated() {
            let btn = TocRowButton(title: item.text.isEmpty ? " " : item.text,
                                   target: self, action: #selector(jump(_:)))
            btn.tag = idx
            btn.indent = CGFloat(item.level - minLevel) * 14
            list.addArrangedSubview(btn)
            btn.leadingAnchor.constraint(equalTo: list.leadingAnchor).isActive = true
            btn.trailingAnchor.constraint(equalTo: list.trailingAnchor).isActive = true
        }

        // Scroll so long documents' outlines stay usable inside the fixed-size popover.
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let flipped = FlippedClip()
        flipped.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(list)
        scroll.documentView = flipped   // MUST precede the flipped↔contentView constraint below — else the
                                        // two anchors have no common ancestor and activate() throws an
                                        // NSException, which AppKit swallows so the TOC tab silently never shows.
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: flipped.topAnchor, constant: 4),
            list.leadingAnchor.constraint(equalTo: flipped.leadingAnchor, constant: 12),
            list.trailingAnchor.constraint(equalTo: flipped.trailingAnchor, constant: -12),
            list.bottomAnchor.constraint(equalTo: flipped.bottomAnchor, constant: -4),
            flipped.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        // A definite height so `fittingSize` (which drives the popover height) is bounded: the list's
        // own height (24px rows + 2px gaps + 8px padding) capped so long outlines scroll instead of
        // growing the popover past a sensible max.
        let rows = CGFloat(outline.count)
        let contentHeight = rows * 24 + max(0, rows - 1) * 2 + 8
        scroll.heightAnchor.constraint(equalToConstant: min(contentHeight, 264)).isActive = true
        return scroll
    }

    @objc private func jump(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < outline.count else { return }
        onJump(outline[sender.tag])     // controller moves caret + scrolls (responder action)
        popover?.performClose(nil)      // minimal UI: close after jumping, like the reference
    }
}

/// A left-aligned, borderless heading row that highlights on hover (so the list reads as clickable
/// like the Tauri `.toc-item`). `indent` shifts the title right by the heading's relative depth.
final class TocRowButton: HoverButton {
    var indent: CGFloat = 0 { didSet { applyTitle() } }
    private var rowTitle = ""

    convenience init(title: String, target: AnyObject, action: Selector) {
        self.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        rowTitle = title
        self.target = target
        self.action = action
        isBordered = false
        bezelStyle = .inline
        alignment = .left
        lineBreakMode = .byTruncatingTail
        font = NSFont.systemFont(ofSize: 13)
        wantsLayer = true
        layer?.cornerRadius = 5
        heightAnchor.constraint(equalToConstant: 24).isActive = true
        (cell as? NSButtonCell)?.imagePosition = .noImage
        applyTitle()
    }

    /// Set the attributed title with the depth indent (firstLineHeadIndent). Called from init + when
    /// `indent` changes — NOT from layout(): setting attributedTitle re-invalidates layout, so doing it
    /// inside layout() risks a re-layout loop.
    private func applyTitle() {
        let p = NSMutableParagraphStyle()
        p.firstLineHeadIndent = 8 + indent
        p.lineBreakMode = .byTruncatingTail
        attributedTitle = NSAttributedString(string: rowTitle, attributes: [
            .paragraphStyle: p,
            .font: font ?? NSFont.systemFont(ofSize: 13),
            .foregroundColor: mallowText])
    }

    override func hoverChanged() {
        layer?.backgroundColor = (hovering ? NSColor(white: 1, alpha: 0.08) : .clear).cgColor
    }
}

/// A top-left-origin clip content view so the TOC list grows downward (NSScrollView is bottom-up by
/// default, which would scroll the heading list upside down).
private final class FlippedClip: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Controller wiring (the @objc target for the titlebar button + the ⇧⌘I View-menu item)

extension EditorController {
    /// Open the document-info popover anchored to the info titlebar button (or, when fired from the
    /// menu, to the window's content top-trailing). Replaces the old `showInfo` words/characters
    /// stub with the two-tab Statistics + Table-of-Contents panel.
    @objc func showDocumentInfo(_ sender: Any?) {
        let source = textView.string
        // Parse for the outline. Reuse the engine (markdown stays the source of truth — read only).
        let blocks = inkParseBlocks(source)
        let stats = DocStats(markdown: source)
        let outline = DocOutline.extract(source, blocks: blocks)
        // The on-disk modified date for the meta row (nil for an unsaved document → row omitted).
        let modified = vm.filePath.flatMap {
            (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date
        }

        let pop = NSPopover()
        pop.contentViewController = InfoPanelViewController(
            stats: stats, outline: outline, modified: modified, popover: pop,
            onJump: { [weak self] item in self?.jumpToOutline(item) })
        configureTransient(pop)   // .transient; follows system appearance (shared with the other popovers)

        // Prefer the info button as the anchor; fall back to the window content's top-trailing.
        if let button = sender as? NSButton {
            pop.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        } else if let content = window?.contentView {
            let anchor = NSRect(x: content.bounds.maxX - 60, y: content.bounds.maxY - 52,
                                width: 1, height: 1)
            pop.show(relativeTo: anchor, of: content, preferredEdge: .minY)
        }
    }

    /// Move the caret to a heading and scroll it into view — the native counterpart of the Tauri
    /// `scrollToHeading` (caret to heading start, then reveal). Selection-only; the buffer is
    /// untouched. `selectionChanged` re-reveals that line's syntax via the view-model.
    fileprivate func jumpToOutline(_ item: OutlineItem) {
        let nsLen = (textView.string as NSString).length
        let loc = min(max(0, item.caretUTF16), nsLen)
        let range = NSRange(location: loc, length: 0)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        window?.makeFirstResponder(textView)   // return focus to the editor after the jump
        vm.selectionChanged()                  // reveal the now-current line's hidden syntax
    }
}
