// ClipboardExtras — the three Mallow clipboard behaviors, as a self-contained slice on top of the
// existing controller/text-view. Markdown-as-truth holds throughout: nothing rewrites the buffer
// except by inserting literal text through the text view (which re-parses on textDidChange) or by
// rendering the engine's HTML for an OUTBOUND copy. The three behaviors:
//   (a) Paste and Match Style (⇧⌘V) — insert the clipboard as PLAIN text at the caret, unparsed.
//   (b) Copy as Rich Text (⌥⌘C)      — put the engine-rendered HTML on the pasteboard (so Slack /
//                                       Docs / Notion keep formatting), markdown source as the
//                                       plain-text fallback.
//   (c) paste-URL-wraps-selection    — ⌘V over a non-empty selection, when the clipboard is a single
//                                       http(s) URL, wraps the selection as `[selection](url)`.
// (a)+(b) are @objc menu targets on EditorController; (c) is the URL-wrap decision, called from a
// MarkdownTextView.paste(_:) override the integrator adds (see the file header's sharedChanges).

import AppKit

// MARK: bare-URL test (mirrors the Tauri reference's isBareUrl in src/editor/urlPaste.ts)

/// True iff `text` is a single http(s) URL: after trimming, it starts with http:// or https:// and
/// has no interior whitespace/newline. Only http(s) is allowed, so a selection can never be wrapped
/// into a dangerous-scheme link (javascript:, data:, …) — consistent with the export sanitizer.
func isBareURL(_ text: String) -> Bool {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard t.hasPrefix("http://") || t.hasPrefix("https://") else { return false }
    return !t.contains(where: { $0.isWhitespace })   // a single token, no spaces/newlines
}

extension EditorController {

    // MARK: (a) Paste and Match Style (⇧⌘V)

    /// Insert the clipboard's PLAIN text at the caret, unparsed — the escape hatch from any smart
    /// transform. Goes through the text view's insertion path (undo-able, respects the selection),
    /// then re-parses like any edit so the new text styles live. Empty/no-text clipboard is a no-op.
    @objc func pasteAsPlainText(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        let r = textView.selectedRange()
        guard textView.shouldChangeText(in: r, replacementString: text) else { return }
        textView.insertText(text, replacementRange: r)   // replaces the selection, like a real paste
        // textDidChange normally drives refresh, but insertText(replacementRange:) does not post it;
        // refresh + chrome explicitly so the inserted text is parsed/styled and the ● dot updates.
        vm.refresh()
        updateChrome()
    }

    // MARK: (b) Copy as Rich Text (⌥⌘C)

    /// Render the document to standalone HTML via the engine and place it on the pasteboard as HTML,
    /// with the markdown source as the plain-text fallback. Pasting into Slack / Mail / Docs / Notion
    /// keeps headings/bold/lists/tables/code; plain-text-only targets get the markdown source.
    @objc func copyAsRichText(_ sender: Any?) {
        let md = textView.string
        guard !md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let title = vm.baseName
        let html = inkRenderHtml(md, title)
        let pb = NSPasteboard.general
        pb.clearContents()
        // Declare BOTH representations on one item so a reader can pick the richest it understands.
        // .html for rich targets; .string (the markdown source) for plain-text-only ones.
        pb.declareTypes([.html, .string], owner: nil)
        pb.setString(html, forType: .html)
        pb.setString(md, forType: .string)
    }

    // MARK: (c) URL-wrap decision (called from MarkdownTextView.paste override — see sharedChanges)

    /// If a single http(s) URL is pasted over a NON-empty selection, replace the selection with
    /// `[selection](url)` and return true (handled). Otherwise return false so the caller falls back
    /// to the normal paste. Markdown-as-truth: we insert the literal markdown text and let the engine
    /// re-parse it (textDidChange → refresh), never a styled run.
    func handleURLWrapPaste() -> Bool {
        let r = textView.selectedRange()
        guard r.length > 0 else { return false }                       // no selection → normal paste
        guard let clip = NSPasteboard.general.string(forType: .string), isBareURL(clip) else {
            return false                                               // clipboard isn't a bare URL
        }
        let url = clip.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = (textView.string as NSString).substring(with: r)
        let replacement = "[\(selected)](\(url))"
        guard textView.shouldChangeText(in: r, replacementString: replacement) else { return true }
        textView.insertText(replacement, replacementRange: r)
        // Place the caret just past the inserted link (after the closing paren), matching a paste.
        textView.setSelectedRange(NSRange(location: r.location + (replacement as NSString).length,
                                          length: 0))
        vm.refresh()        // insertText(replacementRange:) posts no textDidChange — refresh manually
        updateChrome()
        return true
    }

    // MARK: menu enablement

    /// Enable our items only when they can do something: Paste & Match Style needs plain text on the
    /// pasteboard; Copy as Rich Text needs a non-empty document. (NSWindow/NSText built-ins keep
    /// validating themselves; we only answer for our own two selectors.)
    @objc func validateClipboardExtra(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(pasteAsPlainText(_:)):
            return NSPasteboard.general.canReadObject(forClasses: [NSString.self], options: nil)
        case #selector(copyAsRichText(_:)):
            return !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default:
            return true
        }
    }
}
