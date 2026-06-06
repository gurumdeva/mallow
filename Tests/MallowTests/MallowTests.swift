// MallowTests — unit tests for the app's PURE logic. The editor's rendering / layout / multi-window
// behavior is UI and isn't unit-testable, but the pure helpers underneath the recent correctness +
// data-safety fixes are — so these lock them in against regression. Grouped by the area each guards.

import XCTest
import Foundation
import UniformTypeIdentifiers
@testable import Mallow

final class MallowTests: XCTestCase {

    // MARK: Data-safety: UTF-8 / BOM decode (the non-UTF-8 open guard + BOM preservation)

    func testDecodeUTF8_plainText() {
        let r = EditorDocument.decodeUTF8(Data("hello".utf8))
        XCTAssertEqual(r?.text, "hello")
        XCTAssertEqual(r?.hadBOM, false)
    }

    func testDecodeUTF8_stripsAndFlagsBOM() {
        var bytes = Data([0xEF, 0xBB, 0xBF])      // UTF-8 BOM
        bytes.append(contentsOf: "hello".utf8)
        let r = EditorDocument.decodeUTF8(bytes)
        XCTAssertEqual(r?.text, "hello", "the BOM must be stripped from the buffer text")
        XCTAssertEqual(r?.hadBOM, true, "but remembered so save can re-emit it")
    }

    func testDecodeUTF8_rejectsNonUTF8() {
        // A UTF-16LE-looking byte stream (0xFF is never a valid UTF-8 lead byte) must decode to nil,
        // so make(for:) opens it untitled instead of binding the path (the data-loss guard).
        XCTAssertNil(EditorDocument.decodeUTF8(Data([0xFF, 0xFE, 0x68, 0x00])))
    }

    func testDecodeUTF8_emptyIsEmptyNotNil() {
        let r = EditorDocument.decodeUTF8(Data())
        XCTAssertEqual(r?.text, "")
        XCTAssertEqual(r?.hadBOM, false)
    }

    func testDecodeUTF8_preservesCJKAndEmoji() {
        let r = EditorDocument.decodeUTF8(Data("한글 🎉 test".utf8))
        XCTAssertEqual(r?.text, "한글 🎉 test")
    }

    // MARK: Filename validation (rename safety — can't escape the folder)

    func testRenameValidation_addsMdExtension() {
        XCTAssertEqual(RenameValidation.normalize("notes"), "notes.md")
        XCTAssertEqual(RenameValidation.normalize("notes.md"), "notes.md")
        XCTAssertEqual(RenameValidation.normalize("  spaced  "), "spaced.md")
        XCTAssertEqual(RenameValidation.normalize("Report.MD"), "Report.md")  // case-insensitive .md drop
    }

    func testRenameValidation_rejectsUnsafeNames() {
        XCTAssertNil(RenameValidation.normalize(""))
        XCTAssertNil(RenameValidation.normalize("   "))
        XCTAssertNil(RenameValidation.normalize("a/b"))      // path separator
        XCTAssertNil(RenameValidation.normalize("a\\b"))
        XCTAssertNil(RenameValidation.normalize("."))
        XCTAssertNil(RenameValidation.normalize(".."))
        XCTAssertNil(RenameValidation.normalize(".md"))      // empty base after dropping .md
    }

    // MARK: Bare-URL detection (paste-URL-wraps-selection; dangerous schemes excluded)

    func testIsBareURL() {
        XCTAssertTrue(isBareURL("https://example.com"))
        XCTAssertTrue(isBareURL("http://x"))
        XCTAssertTrue(isBareURL("  https://trim.me  "))           // trimmed
        XCTAssertFalse(isBareURL("https://has space.com"))        // interior whitespace
        XCTAssertFalse(isBareURL("ftp://x"))                      // only http(s)
        XCTAssertFalse(isBareURL("javascript:alert(1)"))          // dangerous scheme never wrapped
        XCTAssertFalse(isBareURL("not a url"))
        XCTAssertFalse(isBareURL(""))
    }

    // MARK: Image embed (paste/drop image → inline data-URI markdown)

    func testImageEmbed_markdownDataURI() {
        let md = ImageEmbed.markdown(forImageData: Data("hi".utf8), mime: "image/png", alt: "shot")
        XCTAssertEqual(try md.get(), "![shot](data:image/png;base64,aGk=)")
    }

    func testImageEmbed_rejectsOversize() {
        let big = Data(count: ImageEmbed.maxBytes + 1)
        if case .success = ImageEmbed.markdown(forImageData: big, mime: "image/png", alt: "") {
            XCTFail("an image over the size cap must fail, not embed a multi-MB data URI")
        }
    }

    func testImageEmbed_mimeAndAlt() {
        XCTAssertEqual(ImageEmbed.mime(for: nil), "image/png")
        XCTAssertEqual(ImageEmbed.mime(for: UTType.png), "image/png")
        XCTAssertEqual(ImageEmbed.mime(for: UTType.jpeg), "image/jpeg")
        XCTAssertEqual(ImageEmbed.altFromFileName("Shot 1.png"), "Shot 1")
        XCTAssertEqual(ImageEmbed.altFromFileName("a.b.png"), "a.b")
        XCTAssertEqual(ImageEmbed.altFromFileName("noext"), "noext")
        XCTAssertEqual(ImageEmbed.altFromFileName(nil), "")
        XCTAssertEqual(ImageEmbed.altFromFileName(""), "")
    }

    // MARK: Canonical path (single-writer-per-file de-duplication)

    func testCanonicalPath_dedupesEquivalentSpellings() {
        XCTAssertNil(WindowRegistry.canonicalPath(""))
        // `.` segments + redundant slashes normalize, so two spellings of one file collapse to one identity.
        let a = WindowRegistry.canonicalPath("/tmp/sub/../a.md")
        let b = WindowRegistry.canonicalPath("/tmp/./a.md")
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b)
        // A tilde path expands to an absolute path under the home directory.
        let home = WindowRegistry.canonicalPath("~/note.md")
        XCTAssertNotNil(home)
        XCTAssertTrue(home!.hasPrefix("/"), "tilde must expand to an absolute path")
    }

    // MARK: byte ↔ UTF-16 ↔ scalar offset conversions (engine ranges ↔ NSTextView ranges)

    func testOffsetConversions_asciiIsIdentity() {
        let s = "abcde"
        XCTAssertEqual(utf16ToChar(s, 3), 3)
        XCTAssertEqual(charToUTF16(s, 3), 3)
        XCTAssertEqual(byteToUTF16(s, 3), 3)
    }

    func testOffsetConversions_astralEmojiAndCJK() {
        // "🎉a": 🎉 is 1 Unicode scalar = 2 UTF-16 units = 4 UTF-8 bytes; 'a' follows.
        let s = "🎉a"
        XCTAssertEqual(utf16ToChar(s, 0), 0)
        XCTAssertEqual(utf16ToChar(s, 2), 1, "UTF-16 offset 2 (past the surrogate pair) is scalar 1")
        XCTAssertEqual(charToUTF16(s, 1), 2, "scalar 1 ('a') is UTF-16 offset 2")
        XCTAssertEqual(byteToUTF16(s, 4), 2, "byte 4 ('a') is UTF-16 offset 2")
        // round-trip on a scalar boundary
        XCTAssertEqual(charToUTF16(s, utf16ToChar(s, 2)), 2)
    }

    // MARK: Local image assets (sidecar-file save: naming, extension, relative ref)

    func testImageAsset_assetsDirName() {
        XCTAssertEqual(ImageAsset.assetsDirName(forDocFileName: "draft.md"), "draft.assets")
        XCTAssertEqual(ImageAsset.assetsDirName(forDocFileName: "My Notes.md"), "My Notes.assets")
        XCTAssertEqual(ImageAsset.assetsDirName(forDocFileName: "noext"), "noext.assets")
    }

    func testImageAsset_ext() {
        XCTAssertEqual(ImageAsset.ext(forMime: "image/png"), "png")
        XCTAssertEqual(ImageAsset.ext(forMime: "image/jpeg"), "jpg")
        XCTAssertEqual(ImageAsset.ext(forMime: "image/gif"), "gif")
        XCTAssertEqual(ImageAsset.ext(forMime: "image/svg+xml"), "svg")
        XCTAssertEqual(ImageAsset.ext(forMime: "garbage"), "png")
    }

    func testImageAsset_nextFileNameIsCollisionFree() {
        XCTAssertEqual(ImageAsset.nextFileName(existing: [], ext: "png"), "image-1.png")
        XCTAssertEqual(ImageAsset.nextFileName(existing: ["image-1.png"], ext: "png"), "image-2.png")
        XCTAssertEqual(ImageAsset.nextFileName(existing: ["image-1.png", "image-2.png", "image-3.png"], ext: "png"), "image-4.png")
        XCTAssertEqual(ImageAsset.nextFileName(existing: ["image-1.png"], ext: "jpg"), "image-1.jpg")  // ext-independent
    }

    func testImageAsset_markdownRefWrapsSpacesInAngles() {
        XCTAssertEqual(ImageAsset.markdownRef(alt: "x", relativePath: "draft.assets/image-1.png"),
                       "![x](draft.assets/image-1.png)")
        XCTAssertEqual(ImageAsset.markdownRef(alt: "", relativePath: "My Notes.assets/image-1.png"),
                       "![](<My Notes.assets/image-1.png>)")
    }

    func testImageAsset_saveWritesSidecarFileAndReturnsRelativeRef() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mallow-asset-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let docPath = tmp.appendingPathComponent("draft.md").path

        let ref = ImageAsset.save(Data("PNGBYTES".utf8), mime: "image/png", alt: "pic", nextToDocAt: docPath)
        XCTAssertEqual(ref, "![pic](draft.assets/image-1.png)")
        let saved = tmp.appendingPathComponent("draft.assets/image-1.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path), "the image file must be written")
        XCTAssertEqual(try Data(contentsOf: saved), Data("PNGBYTES".utf8))

        // a second save into the same doc collision-increments the filename
        let ref2 = ImageAsset.save(Data("X".utf8), mime: "image/png", alt: "", nextToDocAt: docPath)
        XCTAssertEqual(ref2, "![](draft.assets/image-2.png)")
    }

    // MARK: Smart typography — context suppression (don't curl quotes where it corrupts structure)

    func testSmartTypography_curlsInProse() {
        // A straight double quote typed in prose becomes an opening curly quote.
        XCTAssertEqual(SmartTypography.substitution(for: "\"", in: "say ", at: 4), "\u{201C}")
        // `--` (a hyphen after a hyphen) becomes an en dash.
        XCTAssertEqual(SmartTypography.substitution(for: "-", in: "a-", at: 2), "\u{2013}")
    }

    func testSmartTypography_suppressedInCode() {
        // Inside an inline backtick span (odd backticks before the caret), no curling.
        XCTAssertNil(SmartTypography.substitution(for: "\"", in: "a `code ", at: 8))
        // Inside a fenced code block.
        XCTAssertNil(SmartTypography.substitution(for: "\"", in: "```\ncode ", at: 9))
    }

    func testSmartTypography_suppressedInLeadingFrontmatter() {
        let fm = "---\ntitle: \n---\n\nbody"
        let inTitle = ("---\ntitle: " as NSString).length          // caret right after "title: "
        XCTAssertNil(SmartTypography.substitution(for: "\"", in: fm, at: inTitle),
                     "a quote inside YAML frontmatter must NOT be curled (would corrupt the YAML)")
        // After the closing ---, the body is prose again → curling resumes.
        let inBody = (fm as NSString).range(of: "body").location
        XCTAssertEqual(SmartTypography.substitution(for: "\"", in: fm, at: inBody), "\u{201C}")
        // A `---` that is NOT at the document start is a thematic break, not frontmatter → still curls.
        let notFm = "hello\n---\nx"
        let afterRule = ("hello\n---\n" as NSString).length
        XCTAssertEqual(SmartTypography.substitution(for: "\"", in: notFm, at: afterRule), "\u{201C}")
    }

    // MARK: - Inline raw HTML coverage (engine data-safety regression, end-to-end through the FFI bridge)

    func testInlineHTML_isCoveredByInlineRuns_notDropped() {
        // The engine used to DROP inline raw HTML (`<br>`, `<span>`, …). The app hides syntax by the
        // COMPLEMENT of the engine's inline runs, so the dropped markup got zero-width-hidden — e.g.
        // `line<br>wrap` rendered on screen as `linewrap` (the bytes only vanished visually; the file
        // stayed byte-exact). The engine now emits a content run for inline HTML. This asserts the fix
        // travels through `inkParseBlocks` (FFI + JSON decode) and that the paragraph's inline runs
        // concatenate back to the full literal text — no on-screen content dropped. ASCII → byte == UTF-16.
        func visibleConcatenation(_ s: String) -> String {
            let u8 = Array(s.utf8)
            return inkParseBlocks(s).flatMap { $0.inlines }.map { inl -> String in
                let lo = max(0, min(inl.range.start, u8.count))
                let hi = max(lo, min(inl.range.end, u8.count))
                return String(decoding: u8[lo ..< hi], as: UTF8.self)
            }.joined()
        }
        XCTAssertEqual(visibleConcatenation("line<br>wrap"), "line<br>wrap")
        XCTAssertEqual(visibleConcatenation("H<sub>2</sub>O"), "H<sub>2</sub>O")
        XCTAssertEqual(visibleConcatenation("a <span>b</span> c"), "a <span>b</span> c")
        // A raw-HTML block nested inside a blockquote (depth>0) is also content now — the `> ` marker
        // stays a gap, the `<div>` shows. (Previously the whole div line vanished on screen.)
        XCTAssertEqual(visibleConcatenation("> <div>x</div>"), "<div>x</div>")
    }

    // MARK: - Update check (GitHub release version comparison)

    func testUpdateChecker_isNewer_numericSemverCompare() {
        // strictly newer (with/without the "v" tag prefix)
        XCTAssertTrue(UpdateChecker.isNewer("v1.0.4", than: "1.0.3"))
        XCTAssertTrue(UpdateChecker.isNewer("2.0.0", than: "1.9.9"))
        // NUMERIC, not lexical: 1.0.10 > 1.0.9 (a string compare would wrongly say "10" < "9")
        XCTAssertTrue(UpdateChecker.isNewer("v1.0.10", than: "1.0.9"))
        // equal → not newer
        XCTAssertFalse(UpdateChecker.isNewer("v1.0.4", than: "1.0.4"))
        // older → not newer
        XCTAssertFalse(UpdateChecker.isNewer("v1.0.3", than: "1.0.4"))
        XCTAssertFalse(UpdateChecker.isNewer("v0.30.2", than: "1.0.0"))
        // a missing trailing component counts as 0: 1.0 == 1.0.0, and 1.0.1 > 1.0
        XCTAssertFalse(UpdateChecker.isNewer("v1.0", than: "1.0.0"))
        XCTAssertTrue(UpdateChecker.isNewer("v1.0.1", than: "1.0"))
        // tolerant of an absent current version (e.g. no app bundle under `swift test` → "0")
        XCTAssertTrue(UpdateChecker.isNewer("v1.0.0", than: "0"))
        // a prerelease / build-metadata tag is NOT a stable upgrade (don't prompt for an rc / beta)
        XCTAssertFalse(UpdateChecker.isNewer("v1.2.0-rc1", than: "1.1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("v2.0.0-beta", than: "1.1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.2.0+build5", than: "1.1.0"))
        XCTAssertTrue(UpdateChecker.isNewer("v1.2.0", than: "1.1.0"))   // a clean stable tag still upgrades
    }
}
