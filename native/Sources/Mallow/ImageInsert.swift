// ImageInsert — paste / drag-drop an image into the editor and embed it as a markdown image with a
// base64 data URI (`![alt](data:image/png;base64,…)`), so the saved .md stays self-contained (no
// sidecar files). Mirrors the Tauri reference's src/editor/imageEmbed.ts + the EditorController image
// paste/drop path: image-only, 10 MB/image cap, a DISTINCT "too large" error vs a generic failure,
// and — for several images at once — one alert per reason rather than one per file.
//
// Layering: the pure byte→data-URI work and the size policy live in `ImageEmbed` (no AppKit text
// state, easy to reason about); the controller extension is the View/Controller seam that reads the
// pasteboard / drag, inserts through the text view's undoable edit path, and surfaces errors. Stored
// state isn't needed, so this stays a single new file; MarkdownTextView only needs to forward
// paste(_:) and the drag methods to its delegate (see sharedChanges) since an extension can neither
// override those nor add the drag-type registration.

import AppKit
import UniformTypeIdentifiers

// MARK: - Embed policy + encoding (pure; no editor/text-view state)

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

// MARK: - One embeddable image gathered from a pasteboard or a drag

/// A single image resolved from the pasteboard / drag: either original file bytes (preferred — keeps
/// the source format) or a bitmap to PNG-encode. Carries the alt text derived from the filename.
private struct PendingImage {
    let markdown: () -> Result<String, ImageEmbed.Failure>
}

// MARK: - Controller seam: read the drop/paste, insert, report

extension EditorController {

    /// Forwarded from `MarkdownTextView.paste(_:)`. Returns true when the pasteboard held image(s)
    /// and we embedded them; false to let the text view run its normal paste (text / engine-agnostic).
    @objc func insertImagesFromPasteboard(_ pasteboard: NSPasteboard) -> Bool {
        let images = pendingImages(from: pasteboard)
        guard !images.isEmpty else { return false }   // no image → fall through to default paste
        embed(images, at: textView.selectedRange().location)
        return true
    }

    /// Forwarded from `MarkdownTextView.performDragOperation(_:)`. Returns true when the drag carried
    /// image(s) and we embedded them at the drop point; false to let the text view handle the drag
    /// (e.g. dragged plain text / internal moves).
    @objc func insertImagesFromDrag(_ sender: NSDraggingInfo) -> Bool {
        let images = pendingImages(from: sender.draggingPasteboard)
        guard !images.isEmpty else { return false }
        // Drop AT the cursor under the pointer; fall back to the current caret if it can't be mapped.
        let view = textView
        let local = view.convert(sender.draggingLocation, from: nil)
        let dropIndex = view.characterIndexForInsertion(at: local)
        embed(images, at: dropIndex)
        view.window?.makeKeyAndOrderFront(nil)
        view.window?.makeFirstResponder(view)
        return true
    }

    // MARK: gather

    /// Pull every embeddable image out of a pasteboard, preferring original file bytes (dragged /
    /// copied files) and falling back to a bitmap image (e.g. a screenshot on the clipboard). Mirrors
    /// imageFilesFrom(): take file URLs first; only consult the bitmap if no image files were found,
    /// so a single image isn't embedded twice.
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

    // MARK: insert + report

    /// Encode + insert each image's markdown at `location` (subsequent images follow the previous
    /// insertion). Goes through the undoable edit path so ⌘Z removes it and `textDidChange` re-runs
    /// the view-model pipeline — the buffer is only ever changed as plain markdown text, never styled
    /// in place (markdown-as-truth). Aggregates failures and alerts once per reason at the end.
    private func embed(_ images: [PendingImage], at location: Int) {
        let view = textView
        var tooLarge = 0
        var failed = 0
        var caret = max(0, min(location, (view.string as NSString).length))

        for image in images {
            switch image.markdown() {
            case .failure(.tooLarge): tooLarge += 1
            case .failure(.failed):   failed += 1
            case .success(var md):
                // Standalone image → put it on its own line(s) so it isn't glued to adjacent text and
                // parses as an image. Only pad where there isn't already a line break.
                let ns = view.string as NSString
                let before = caret > 0 ? ns.character(at: caret - 1) : 10            // 10 = \n
                let after = caret < ns.length ? ns.character(at: caret) : 10
                if before != 10 { md = "\n" + md }
                if after != 10 { md += "\n" }
                let range = NSRange(location: caret, length: 0)
                guard view.shouldChangeText(in: range, replacementString: md) else { continue }
                view.textStorage?.replaceCharacters(in: range, with: md)
                view.didChangeText()                                                // fires textDidChange → vm.refresh()
                caret += (md as NSString).length
                view.setSelectedRange(NSRange(location: caret, length: 0))
            }
        }

        if tooLarge > 0 { presentImageError(tooLarge: true) }
        if failed > 0 { presentImageError(tooLarge: false) }
    }

    /// A non-blocking sheet matching the reference's two toasts: a DISTINCT message for the size cap
    /// vs a generic add failure. Falls back to a modal alert if there's no window to attach a sheet to.
    private func presentImageError(tooLarge: Bool) {
        let alert = NSAlert()
        alert.messageText = tooLarge ? "Image is too large (max 10 MB)" : "Couldn't add the image"
        alert.alertStyle = tooLarge ? .warning : .informational
        if let window = window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}
