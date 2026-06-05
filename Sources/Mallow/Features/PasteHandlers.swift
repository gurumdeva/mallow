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

// MARK: - Local image asset (save next to the doc instead of an inline data-URI)

/// Saves a pasted/dropped image as a SIDECAR file next to the document — `<docfolder>/<docname>.assets/
/// image-<N>.<ext>` — and returns the markdown `![alt](<relative-path>)`. Far smaller than an inline
/// `data:` base64 URI, which bloats both the `.md` AND the editor view (the source string is what shows).
/// The naming / extension / relative-path math is factored into pure helpers so it's unit-tested; only
/// `save` touches the filesystem.
enum ImageAsset {
    /// The sidecar directory name for a document file: "draft.md" → "draft.assets" (Typora-style).
    static func assetsDirName(forDocFileName name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        return (base.isEmpty ? name : base) + ".assets"
    }

    /// A file extension for an image MIME: "image/jpeg" → "jpg", "image/svg+xml" → "svg", else the
    /// subtype (alphanumerics only), defaulting to "png".
    static func ext(forMime mime: String) -> String {
        let lower = mime.lowercased()
        guard lower.hasPrefix("image/") else { return "png" }   // not an image MIME → default to png
        let sub = String(lower.dropFirst(6))
        switch sub {
        case "jpeg": return "jpg"
        case "svg+xml": return "svg"
        default:
            let clean = String(sub.filter { $0.isLetter || $0.isNumber })
            return clean.isEmpty ? "png" : clean
        }
    }

    /// The first `image-<N>.<ext>` (N from 1) not already present in `existing` — collision-free naming.
    static func nextFileName(existing: Set<String>, ext: String) -> String {
        var n = 1
        while existing.contains("image-\(n).\(ext)") { n += 1 }
        return "image-\(n).\(ext)"
    }

    /// A markdown image link to a relative path, wrapping the destination in `<…>` when it contains a
    /// space or paren (which would otherwise break the link) so a doc name with spaces still resolves.
    static func markdownRef(alt: String, relativePath: String) -> String {
        let needsAngles = relativePath.contains(where: { $0 == " " || $0 == "(" || $0 == ")" })
        let dest = needsAngles ? "<\(relativePath)>" : relativePath
        return "![\(alt)](\(dest))"
    }

    /// Write `data` into the document's sidecar `.assets` folder (created if needed) and return the
    /// `![alt](relpath)` markdown, or nil on any IO failure (the caller then falls back to a data-URI).
    static func save(_ data: Data, mime: String, alt: String, nextToDocAt docPath: String) -> String? {
        let docURL = URL(fileURLWithPath: docPath)
        let dirName = assetsDirName(forDocFileName: docURL.lastPathComponent)
        let assetsDir = docURL.deletingLastPathComponent().appendingPathComponent(dirName)
        let fm = FileManager.default
        guard (try? fm.createDirectory(at: assetsDir, withIntermediateDirectories: true)) != nil else { return nil }
        let existing = Set((try? fm.contentsOfDirectory(atPath: assetsDir.path)) ?? [])
        let fileName = nextFileName(existing: existing, ext: ext(forMime: mime))
        guard (try? data.write(to: assetsDir.appendingPathComponent(fileName), options: .atomic)) != nil else { return nil }
        return markdownRef(alt: alt, relativePath: dirName + "/" + fileName)
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

/// A single image resolved from the pasteboard / drag: its alt text + MIME, plus a closure that defers
/// the (potentially large) byte read — original file bytes (preferred, keeps the source format) or a
/// PNG-encoded clipboard bitmap — until insertion time, where `embed` decides sidecar-file vs data-URI.
private struct PendingImage {
    let alt: String
    let mime: String
    let bytes: () -> Data?
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
            embed(images, replacing: doc.textView.selectedRange())   // a paste REPLACES the selection
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
            guard view.insertTextUndoably(replacement, replacing: sel) else { return true }   // undoable; fires textDidChange → refresh
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
        // A drop inserts AT the drop point and must NOT replace a selection elsewhere → length 0.
        embed(images, replacing: NSRange(location: dropIndex, length: 0))
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
        guard view.insertTextUndoably(plain, replacing: r) else { return }   // replaces the selection, undoable, fires refresh
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
        // Declare BOTH representations on one item so a reader can pick the richest it understands:
        // .html for rich targets; .string (the markdown source) for plain-text-only ones. declareTypes
        // also clears the prior contents, so no separate clearContents() is needed.
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
                out.append(PendingImage(alt: ImageEmbed.altFromFileName(url.lastPathComponent),
                                        mime: ImageEmbed.mime(for: type),
                                        bytes: { try? Data(contentsOf: url) }))
            }
        }

        // 2) No image files → a raw bitmap on the pasteboard (clipboard screenshot, an app that wrote
        //    only image data). Encode to PNG; alt is empty (there's no filename).
        if out.isEmpty,
           pb.canReadItem(withDataConformingToTypes: [UTType.image.identifier]),
           let image = NSImage(pasteboard: pb) {
            out.append(PendingImage(alt: "", mime: "image/png", bytes: { ImageEmbed.pngData(from: image) }))
        }
        return out
    }

    // MARK: insert — embed each image's markdown at a char location

    /// Encode + insert each image's markdown, REPLACING `initial` on the first image (so a paste over a
    /// selection replaces it like a normal paste; a drop passes a length-0 range so it inserts at the drop
    /// point without touching any selection). Subsequent images follow the previous insertion. Goes through
    /// the text view's undoable insertion path so ⌘Z removes it and textDidChange re-runs the view-model
    /// pipeline — the buffer is only ever changed as plain markdown text, never styled in place
    /// (markdown-as-truth). Un-embeddable images (too large / unreadable) are skipped silently here, since
    /// the new SwiftUI coordinator has no window/alert seam; if at least one image inserts we still report
    /// handled. Bumps `doc.revision` once for the chrome.
    private func embed(_ images: [PendingImage], replacing initial: NSRange) {
        let view = doc.textView
        let total = (view.string as NSString).length
        // Clamp the initial (selection / drop) range into the live buffer; the first insert replaces it,
        // then `range` collapses to a length-0 caret so later images insert after the previous one.
        let loc = max(0, min(initial.location, total))
        var range = NSRange(location: loc, length: max(0, min(initial.length, total - loc)))
        var insertedAny = false

        for image in images {
            guard let data = image.bytes() else { continue }   // unreadable
            // A SAVED document → write the image as a sidecar file and reference it with a short relative
            // path (no giant `data:` base64 bloating the .md + the editor view). An UNTITLED document has
            // no folder to save beside, so fall back to an inline data-URI (size-capped). A failed save
            // also falls back, so an image is never silently dropped.
            var md: String
            if let docPath = doc.vm.filePath,
               let ref = ImageAsset.save(data, mime: image.mime, alt: image.alt, nextToDocAt: docPath) {
                md = ref
            } else if case .success(let dataURI) = ImageEmbed.markdown(forImageData: data, mime: image.mime, alt: image.alt) {
                md = dataURI
            } else {
                continue   // too large for a data-URI and no doc folder to save into
            }
            // Standalone image → put it on its own line(s) so it isn't glued to adjacent text and
            // parses as an image. Pad only where the chars bracketing the range aren't already breaks.
            let ns = view.string as NSString
            let before = range.location > 0 ? ns.character(at: range.location - 1) : 10   // 10 = \n
            let afterIdx = range.location + range.length
            let after = afterIdx < ns.length ? ns.character(at: afterIdx) : 10
            if before != 10 { md = "\n" + md }
            if after != 10 { md += "\n" }
            guard view.insertTextUndoably(md, replacing: range) else { continue }   // undoable; fires textDidChange → vm.refresh()
            let caret = range.location + (md as NSString).length
            view.setSelectedRange(NSRange(location: caret, length: 0))
            range = NSRange(location: caret, length: 0)   // next image inserts after this one (no replace)
            insertedAny = true
        }

        if insertedAny { doc.revision &+= 1 }
    }
}
