// PasteHandlers — the SwiftUI-rewrite re-port of Mallow's clipboard / drag image behaviors, as a
// self-contained slice on top of the editor's `MarkdownEditor.Coordinator` (the NSTextViewDelegate
// that owns the document). It folds the two old AppKit files — ImageInsert.swift (paste/drop an image
// → inline base64 data-URI markdown) and ClipboardExtras.swift (paste-and-match-style, copy-as-rich-
// text, URL-wrap-selection paste) — into one extension, re-pointed at the new seam.
//
// Markdown-as-truth holds throughout: the buffer is only ever changed by inserting LITERAL markdown
// text through the text view's undoable insertion path (which re-parses on textDidChange → vm.refresh),
// or by rendering the engine's HTML for an OUTBOUND copy — never a styled run written in place.
//
// Why an extension on the Coordinator: the new MarkdownTextView can't override paste/drag to do this
// work itself without reaching back into the document/VM, and the Coordinator already holds `doc`
// (text view + view-model). The Coordinator's own `vm` is private, so this file goes through
// `doc.vm` / `doc.textView`. Integration: MarkdownTextView.paste / performDragOperation / drag-entered
// forward to these methods, and the Edit menu targets the two
// menu actions.
//
// Insertion contract (per the editor's design): `doc.textView.insertText(md, replacementRange:)` is
// undoable AND fires the delegate's textDidChange → vm.refresh() automatically, so styles re-derive
// without a manual refresh; we only bump `doc.revision` so the SwiftUI chrome (title / dirty dot)
// re-evaluates.

import AppKit
import UniformTypeIdentifiers

// MARK: - Embed policy + encoding (pure; no editor/text-view state) — copied verbatim from ImageInsert.swift

enum ImageEmbed {
    /// Upper bound per image — large data URIs bloat and slow the document. Matches the reference's
    /// MAX_IMAGE_BYTES (10 MB), measured on the bytes actually embedded.
    static let maxBytes = 10 * 1024 * 1024   // 10 MB

    /// Why an image couldn't be embedded — surfaced one-per-reason so a multi-image drop with the
    /// same problem doesn't stack identical alerts. Conforms to `Error` so it can be a `Result`
    /// failure type.
    enum Failure: Error { case tooLarge, failed }

    /// A markdown `![alt](data:<mime>;base64,<…>)` for raw image bytes, or a `Failure` if the bytes
    /// exceed the cap. `alt` is inserted verbatim (caller strips the file extension); `mime` is the
    /// image's own type so original-format files (jpeg/gif/webp/…) round-trip without re-encoding.
    static func markdown(forImageData data: Data, mime: String, alt: String) -> Result<String, Failure> {
        guard data.count <= maxBytes else { return .failure(.tooLarge) }
        let uri = "data:\(mime);base64,\(data.base64EncodedString())"
        return .success("![\(alt)](\(uri))")
    }

    /// Best-effort `image/<subtype>` for a UTI, defaulting to PNG (what we encode bitmaps as).
    static func mime(for type: UTType?) -> String {
        if let mt = type?.preferredMIMEType, mt.hasPrefix("image/") { return mt }
        return "image/png"
    }

    /// alt text from a filename: drop the path + the trailing extension (`Shot 1.png` → `Shot 1`),
    /// keeping any earlier dots. Empty string when there's no usable name (e.g. a pasted bitmap).
    static func altFromFileName(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return "" }
        let base = (name as NSString).lastPathComponent
        let stem = (base as NSString).deletingPathExtension
        return stem.isEmpty ? base : stem
    }

    /// PNG bytes for a pasteboard/dragged image that arrived as a bitmap (no backing file): the
    /// reference reads original file bytes, but a clipboard screenshot has only pixels, so we encode.
    static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

// MARK: - bare-URL test (mirrors the Tauri reference's isBareUrl) — copied verbatim from ClipboardExtras.swift

/// True iff `text` is a single http(s) URL: after trimming, it starts with http:// or https:// and
/// has no interior whitespace/newline. Only http(s) is allowed, so a selection can never be wrapped
/// into a dangerous-scheme link (javascript:, data:, …) — consistent with the export sanitizer.
func isBareURL(_ text: String) -> Bool {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard t.hasPrefix("http://") || t.hasPrefix("https://") else { return false }
    return !t.contains(where: { $0.isWhitespace })   // a single token, no spaces/newlines
}

// MARK: - One embeddable image gathered from a pasteboard or a drag

/// A single image resolved from the pasteboard / drag: either original file bytes (preferred — keeps
/// the source format) or a bitmap to PNG-encode. The closure defers the (potentially large) byte read
/// + base64 until insertion time. Carries the alt text derived from the filename inside the closure.
private struct PendingImage {
    let markdown: () -> Result<String, ImageEmbed.Failure>
}

// MARK: - Coordinator seam: read the paste/drop, insert, copy out

extension MarkdownEditor.Coordinator {

    // MARK: paste (image embed → URL-wrap → fall through)

    /// Forwarded from `MarkdownTextView.paste(_:)` BEFORE `super.paste`. Returns true when we handled
    /// the paste (so the caller skips the normal text paste), false to let the text view paste as usual.
    ///
    /// Order mirrors the old merged paste override: (1) if the pasteboard holds image(s), embed them as
    /// inline data-URI markdown at the selection; else (2) if the clipboard is a single http(s) URL AND
    /// there's a non-empty selection, wrap the selection as `[selection](url)`; else (3) fall through.
    func handlePaste() -> Bool {
        // (1) Image embed — takes precedence over URL-wrap (an image on the clipboard is the intent).
        let images = pendingImages(from: NSPasteboard.general)
        if !images.isEmpty {
            embed(images, at: doc.textView.selectedRange().location)
            return true
        }

        // (2) URL-wrap: a bare http(s) URL pasted over a NON-empty selection → `[selection](url)`.
        let view = doc.textView
        let sel = view.selectedRange()
        if sel.length > 0,
           let clip = NSPasteboard.general.string(forType: .string), isBareURL(clip) {
            let url = clip.trimmingCharacters(in: .whitespacesAndNewlines)
            let selected = (view.string as NSString).substring(with: sel)
            let replacement = "[\(selected)](\(url))"
            guard view.shouldChangeText(in: sel, replacementString: replacement) else { return true }
            view.insertText(replacement, replacementRange: sel)   // undoable; fires textDidChange → refresh
            // Place the caret just past the inserted link (after the closing paren), matching a paste.
            view.setSelectedRange(NSRange(location: sel.location + (replacement as NSString).length,
                                          length: 0))
            doc.revision &+= 1   // nudge the SwiftUI chrome (title / dirty dot)
            return true
        }

        return false   // (3) nothing of ours applied → normal text paste
    }

    // MARK: drop (image embed at the drop point)

    /// Forwarded from `MarkdownTextView.performDragOperation(_:)`. Returns true when the drag carried
    /// image(s) and we embedded them at the drop point; false to let NSTextView handle the drag (e.g.
    /// dragged plain text / internal moves).
    func handleDrop(_ sender: NSDraggingInfo) -> Bool {
        let images = pendingImages(from: sender.draggingPasteboard)
        guard !images.isEmpty else { return false }
        // Drop AT the cursor under the pointer; fall back to the current caret if it can't be mapped.
        let view = doc.textView
        let local = view.convert(sender.draggingLocation, from: nil)
        let dropIndex = view.characterIndexForInsertion(at: local)
        embed(images, at: dropIndex)
        view.window?.makeKeyAndOrderFront(nil)
        view.window?.makeFirstResponder(view)
        return true
    }

    /// Forwarded from `MarkdownTextView.draggingEntered(_:)` to decide the cursor badge / acceptance:
    /// true iff the drag pasteboard carries file-URL image(s) or raw image data. Mirrors the old
    /// draggingEntered check exactly so the (+) copy badge shows only for embeddable image drags.
    func acceptsImageDrag(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        return pb.canReadObject(forClasses: [NSURL.self],
                                options: [.urlReadingFileURLsOnly: true,
                                          .urlReadingContentsConformToTypes: [UTType.image.identifier]])
            || pb.canReadItem(withDataConformingToTypes: [UTType.image.identifier])
    }

    // MARK: Paste and Match Style (⇧⌘V)

    /// Insert the clipboard's PLAIN text at the selection, unparsed — the escape hatch from any smart
    /// transform. Goes through the undoable insertion path (which re-parses on textDidChange), replacing
    /// the selection like a real paste. Empty / no-text clipboard is a no-op.
    func pasteAndMatchStyle() {
        guard let plain = NSPasteboard.general.string(forType: .string), !plain.isEmpty else { return }
        let view = doc.textView
        let r = view.selectedRange()
        guard view.shouldChangeText(in: r, replacementString: plain) else { return }
        view.insertText(plain, replacementRange: r)   // replaces the selection, undoable, fires refresh
        doc.revision &+= 1
    }

    // MARK: Copy as Rich Text (⌥⌘C)

    /// Render the document to standalone HTML via the engine and place it on the pasteboard as HTML,
    /// with the markdown source as the plain-text fallback. Pasting into Slack / Mail / Docs / Notion
    /// keeps headings/bold/lists/tables/code; plain-text-only targets get the markdown source. No-op on
    /// an empty document.
    func copyAsRichText() {
        let md = doc.textView.string
        guard !md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let html = inkRenderHtml(md, doc.vm.baseName)
        let pb = NSPasteboard.general
        pb.clearContents()
        // Declare BOTH representations on one item so a reader can pick the richest it understands:
        // .html for rich targets; .string (the markdown source) for plain-text-only ones.
        pb.declareTypes([.html, .string], owner: nil)
        pb.setString(html, forType: .html)
        pb.setString(md, forType: .string)
    }

    // MARK: gather — pull embeddable images out of a pasteboard

    /// Pull every embeddable image out of a pasteboard, preferring original file bytes (dragged /
    /// copied files) and falling back to a bitmap image (e.g. a clipboard screenshot). Mirrors the old
    /// imageFilesFrom(): take file URLs first; only consult the bitmap if no image files were found, so
    /// a single image isn't embedded twice.
    private func pendingImages(from pb: NSPasteboard) -> [PendingImage] {
        var out: [PendingImage] = []

        // 1) File references (Finder drag, copied files): read each file's own bytes + MIME, so a
        //    jpeg/gif/webp keeps its format and an animated GIF stays animated.
        let urlOpts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: urlOpts) as? [URL] {
            for url in urls {
                let type = UTType(filenameExtension: url.pathExtension)
                guard type?.conforms(to: .image) == true else { continue }   // images only
                let alt = ImageEmbed.altFromFileName(url.lastPathComponent)
                out.append(PendingImage(markdown: {
                    guard let data = try? Data(contentsOf: url) else {
                        return .failure(ImageEmbed.Failure.failed)
                    }
                    return ImageEmbed.markdown(forImageData: data,
                                               mime: ImageEmbed.mime(for: type), alt: alt)
                }))
            }
        }

        // 2) No image files → a raw bitmap on the pasteboard (clipboard screenshot, an app that wrote
        //    only image data). Encode to PNG; alt is empty (there's no filename).
        if out.isEmpty,
           pb.canReadItem(withDataConformingToTypes: [UTType.image.identifier]),
           let image = NSImage(pasteboard: pb) {
            out.append(PendingImage(markdown: {
                guard let png = ImageEmbed.pngData(from: image) else {
                    return .failure(ImageEmbed.Failure.failed)
                }
                return ImageEmbed.markdown(forImageData: png, mime: "image/png", alt: "")
            }))
        }
        return out
    }

    // MARK: insert — embed each image's markdown at a char location

    /// Encode + insert each image's markdown at `location` (subsequent images follow the previous
    /// insertion). Goes through the text view's undoable insertion path so ⌘Z removes it and
    /// textDidChange re-runs the view-model pipeline — the buffer is only ever changed as plain markdown
    /// text, never styled in place (markdown-as-truth). Un-embeddable images (too large / unreadable)
    /// are skipped silently here, since the new SwiftUI coordinator has no window/alert seam; if at
    /// least one image inserts we still report handled. Bumps `doc.revision` once for the chrome.
    private func embed(_ images: [PendingImage], at location: Int) {
        let view = doc.textView
        var caret = max(0, min(location, (view.string as NSString).length))
        var insertedAny = false

        for image in images {
            guard case .success(var md) = image.markdown() else { continue }   // skip tooLarge / failed
            // Standalone image → put it on its own line(s) so it isn't glued to adjacent text and
            // parses as an image. Only pad where there isn't already a line break.
            let ns = view.string as NSString
            let before = caret > 0 ? ns.character(at: caret - 1) : 10            // 10 = \n
            let after = caret < ns.length ? ns.character(at: caret) : 10
            if before != 10 { md = "\n" + md }
            if after != 10 { md += "\n" }
            let range = NSRange(location: caret, length: 0)
            guard view.shouldChangeText(in: range, replacementString: md) else { continue }
            view.insertText(md, replacementRange: range)   // undoable; fires textDidChange → vm.refresh()
            caret += (md as NSString).length
            view.setSelectedRange(NSRange(location: caret, length: 0))
            insertedAny = true
        }

        if insertedAny { doc.revision &+= 1 }
    }
}
