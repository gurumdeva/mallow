// MallowTests — unit tests for the app's PURE logic. The editor's rendering / layout / multi-window
// behavior is UI and isn't unit-testable, but the pure helpers underneath the recent correctness +
// data-safety fixes are — so these lock them in against regression. Grouped by the area each guards.

import XCTest
import Foundation
import AppKit
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

    func testSmartTypography_lineLeadingDashesStayLiteral() {
        // A thematic break and a GFM table delimiter row must be TYPEABLE: a hyphen on a line that is only
        // hyphens / pipes / colons must NOT be turned into an en/em dash. (The old carve-out only fired at
        // document offset 0, so every other line's `--`/`---` got curled — breaking rules and tables.)
        XCTAssertNil(SmartTypography.substitution(for: "-", in: "x\n-", at: 3))    // 2nd `-` of a line-leading `--`
        XCTAssertNil(SmartTypography.substitution(for: "-", in: "x\n--", at: 4))   // 3rd `-` of `---`
        XCTAssertNil(SmartTypography.substitution(for: "-", in: "|-", at: 2))      // GFM delimiter `|--`
        XCTAssertNil(SmartTypography.substitution(for: "-", in: "| :-", at: 4))    // aligned delimiter `| :--`
        // But a real mid-word hyphen in prose still becomes an en dash.
        XCTAssertEqual(SmartTypography.substitution(for: "-", in: "well-", at: 5), "\u{2013}")
        XCTAssertEqual(SmartTypography.substitution(for: "-", in: "a-", at: 2), "\u{2013}")
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

    // MARK: - Launch-open routing (the duplicate-window-on-launch guard)

    // The pure decision behind MallowApp's `.mallowOpenFile` handler: when the OS hands the app a file,
    // what should the receiving window do? Locks in the fix for "launching with a file opens TWO windows"
    // (a restored-last-file window PLUS the opened-file window).

    func testLaunchOpen_sameFileInThisWindow_focusesNotDuplicates() {
        // The receiving window already shows the opened file (e.g. the restored last file IS the file the
        // launch opened) — focus it, never a second identical window. True regardless of phase/role.
        let a = LaunchOpen.decide(openPath: "/tmp/a.md", receivingWindowPath: "/tmp/a.md",
                                  receivingWindowIsDirty: false, receivingWindowIsInitial: true, isLaunching: true)
        XCTAssertEqual(a, .focusThisWindow)
        // Same file via an equivalent spelling (`.`/`..`/redundant slash) still counts as the same file.
        let b = LaunchOpen.decide(openPath: "/tmp/sub/../a.md", receivingWindowPath: "/tmp/./a.md",
                                  receivingWindowIsDirty: false, receivingWindowIsInitial: false, isLaunching: false)
        XCTAssertEqual(b, .focusThisWindow)
    }

    func testLaunchOpen_launchDifferentFileOnCleanInitialWindow_supersedes() {
        // Cold launch, the spurious clean restore/welcome window, a DIFFERENT file → open the file and
        // close the spurious window (the core fix).
        let r = LaunchOpen.decide(openPath: "/tmp/opened.md", receivingWindowPath: "/tmp/lastfile.md",
                                  receivingWindowIsDirty: false, receivingWindowIsInitial: true, isLaunching: true)
        XCTAssertEqual(r, .openAndSupersede)
        // The welcome window (no file) on first-run launch is likewise superseded by an opened file.
        let w = LaunchOpen.decide(openPath: "/tmp/opened.md", receivingWindowPath: nil,
                                  receivingWindowIsDirty: false, receivingWindowIsInitial: true, isLaunching: true)
        XCTAssertEqual(w, .openAndSupersede)
    }

    func testLaunchOpen_dirtyInitialWindow_doesNotDiscard() {
        // If the user already typed into the restore window before the launch open arrived, never close
        // it (that would discard unsaved edits) — open the file in its own window instead.
        let r = LaunchOpen.decide(openPath: "/tmp/opened.md", receivingWindowPath: "/tmp/lastfile.md",
                                  receivingWindowIsDirty: true, receivingWindowIsInitial: true, isLaunching: true)
        XCTAssertEqual(r, .openNewWindow)
    }

    func testLaunchOpen_afterLaunch_opensNewWindow() {
        // Once the launch phase is over, opening a file always gets its own window (matches File ▸ Open),
        // even on the (now ordinary) initial window — no superseding a window the user is using.
        let r = LaunchOpen.decide(openPath: "/tmp/opened.md", receivingWindowPath: "/tmp/lastfile.md",
                                  receivingWindowIsDirty: false, receivingWindowIsInitial: true, isLaunching: false)
        XCTAssertEqual(r, .openNewWindow)
    }

    func testLaunchOpen_nonInitialWindowDuringLaunch_opensNewWindow() {
        // A file-open received by a window that is NOT the spurious initial one never supersedes it.
        let r = LaunchOpen.decide(openPath: "/tmp/opened.md", receivingWindowPath: "/tmp/other.md",
                                  receivingWindowIsDirty: false, receivingWindowIsInitial: false, isLaunching: true)
        XCTAssertEqual(r, .openNewWindow)
    }

    // MARK: Hidden set — a paragraph's leading whitespace stays VISIBLE (the leading-space peel)

    func testHideBlockGaps_paragraphLeadingWhitespaceVisible_markersStillHidden() {
        // Drives the real hide pipeline (parse → recomputeHidden) and reads the resulting hidden set.
        // `tv` is retained by this scope; the view model holds it weakly.
        let tv = MarkdownTextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let vm = EditorViewModel(textView: tv)
        func hidden(_ s: String) -> Set<Int> { tv.string = s; vm.refresh(); return vm.hiddenChars }

        // THE FIX: a paragraph's leading spaces are content, not syntax — they must NOT be zero-width-hidden
        // (typing spaces at the start of a paragraph used to show nothing). Symmetric to the trailing peel.
        let para = hidden("   hello")        // 3 leading spaces + "hello"
        XCTAssertFalse(para.contains(0), "paragraph leading space @0 must stay visible")
        XCTAssertFalse(para.contains(1), "paragraph leading space @1 must stay visible")
        XCTAssertFalse(para.contains(2), "paragraph leading space @2 must stay visible")

        // The peel is WHITESPACE-ONLY: a leading escape backslash in a paragraph is syntax → still hidden.
        XCTAssertTrue(hidden("\\*x").contains(0), "a paragraph's leading escape backslash must still hide")

        // REGRESSION (the peel is scoped to Paragraph): the `#` marker of a heading still hides — the fix
        // must not leak into Heading/List/BlockQuote. (A heading's ≤3-space indent is outside pulldown's
        // heading block range, so it isn't part of this hide pass either way; the marker is the guard.)
        XCTAssertTrue(hidden("# Heading").contains(0), "the heading # marker must still hide")

        // REGRESSION: a blockquote marker still hides (a bar is drawn in its place).
        XCTAssertTrue(hidden("> quote").contains(0), "the blockquote > must still hide")
    }

    // MARK: Hidden set — a heading marker on a TEXT-LESS line shows (setext underline / lone `#`)

    func testShowOrphanHeadingMarkers_setextUnderlineAndLoneHashVisible() {
        let tv = MarkdownTextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let vm = EditorViewModel(textView: tv)
        func hidden(_ s: String) -> Set<Int> { tv.string = s; vm.refresh(); return vm.hiddenChars }

        // THE REPORTED BUG: `text\n-` is a setext heading. The text renders as a plain paragraph (v1.1.3),
        // so the underline `-`/`=` must show as plain text instead of vanishing (you typed it; you should
        // see it — it becomes a list/heading once it gains content).
        XCTAssertFalse(hidden("Hi\n-").contains(3), "setext H2 underline `-` @3 must show")
        let eq = hidden("Hi\n===")                                // setext H1 — `===` at 3,4,5
        XCTAssertFalse(eq.contains(3), "setext H1 underline `=` @3 must show")
        XCTAssertFalse(eq.contains(5), "setext H1 underline `=` @5 must show")
        XCTAssertFalse(hidden("안녕\n-").contains(3), "the `-` under 안녕 (exact reported case) must show")

        // The bare `#` of an EMPTY heading still being typed shows (was invisible).
        XCTAssertFalse(hidden("#").contains(0), "a lone `#` must show")

        // REGRESSION: a real ATX heading still hides its `# ` marker (text shares the line); text shows.
        let h = hidden("# H")
        XCTAssertTrue(h.contains(0), "the `#` of `# H` must still hide")
        XCTAssertTrue(h.contains(1), "the space after `#` must still hide")
        XCTAssertFalse(h.contains(2), "the heading text H must show")
        // REGRESSION: a closing ATX `#` stays hidden — it's on the text's line.
        XCTAssertTrue(hidden("# H #").contains(4), "a closing `#` must still hide")
        // REGRESSION (not a heading): a paragraph's closing `**` stays hidden.
        XCTAssertTrue(hidden("x **b**").contains(5), "a paragraph's closing ** must still hide")
    }

    // MARK: Hidden set — a lone list marker (`-`/`*`/`+`/`1.`) with no content shows literally

    func testShowOrphanMarkers_loneListBulletVisible() {
        let tv = MarkdownTextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let vm = EditorViewModel(textView: tv)
        func hidden(_ s: String) -> Set<Int> { tv.string = s; vm.refresh(); return vm.hiddenChars }

        // THE REPORTED BUG: a lone list marker is an EMPTY list item. The bullet pipeline only draws `•`
        // for `- ` (dash + space), so a bare marker was neither bulleted nor kept → hidden → invisible.
        // It must show literally until it gains the space/content that turns it into a real bullet.
        XCTAssertFalse(hidden("-").contains(0), "a lone `-` must show")
        XCTAssertFalse(hidden("*").contains(0), "a lone `*` must show")
        XCTAssertFalse(hidden("+").contains(0), "a lone `+` must show")
        let ord = hidden("1.")
        XCTAssertFalse(ord.contains(0), "a lone `1.` must show (digit)")
        XCTAssertFalse(ord.contains(1), "a lone `1.` must show (dot)")

        // REGRESSION: a real list item with content still shows its text (and the `- ` is bulleted, not
        // revealed — it shares the text's line, so the generalized rule leaves it to the bullet pass).
        XCTAssertFalse(hidden("- x").contains(2), "list item text must show")
        // REGRESSION: a paragraph's closing `**` and a real heading's `#` are NOT over-revealed.
        XCTAssertTrue(hidden("a **b**").contains(6), "a paragraph's closing ** must still hide")
        XCTAssertTrue(hidden("# H").contains(0), "a real heading's `#` must still hide")
    }

    // MARK: Table rendering — a long LAST column wraps via a hanging indent (display-only, the row grows
    // taller); a table that fits is byte-identical to before. Locks in the overflow branch of
    // TableRendering.style so a future change can't silently drop the wrap — or start wrapping tables
    // that fit (which would regress every existing table).

    func testTableWrap_longLastColumnHangsIndent_fittingTableUnchanged() {
        // Narrow frame + a pinned container size so the overflow decision is deterministic headlessly (no
        // window to lay out + track). The Restyler derives availableWidth = size.width − 2·padding − inset.
        let tv = MarkdownTextView(frame: CGRect(x: 0, y: 0, width: 360, height: 300))
        tv.textContainer?.size = NSSize(width: 360, height: 100_000)
        let vm = EditorViewModel(textView: tv)

        // (headIndent − firstLineHeadIndent) on the table's row paragraph style: > 0 ⇒ a hanging indent is
        // engaged (the last column wraps under its own column); ≈ 0 ⇒ the plain fit path. Plus the count of
        // horizontal row-separator rules (header excluded).
        func probe(_ s: String) -> (hang: CGFloat, ruleRows: Int)? {
            tv.string = s
            vm.refresh()
            guard let grid = tv.tableGrids.first,
                  let p = tv.textStorage?.attribute(.paragraphStyle, at: grid.blockRange.location,
                                                    effectiveRange: nil) as? NSParagraphStyle else { return nil }
            return (p.headIndent - p.firstLineHeadIndent, grid.rowStartChars.count)
        }

        // A long LAST column can't fit 360pt → it wraps, so the row paragraph gets a hanging indent.
        let wide = """
        | A | B | Note |
        |---|---|---|
        | x | y | A deliberately long note that cannot possibly fit inside the narrow pinned container so the last column has to wrap onto several lines. |
        """
        let w = probe(wide)
        XCTAssertNotNil(w, "wide table should produce a grid")
        XCTAssertGreaterThan(w?.hang ?? 0, 1, "a long last column must engage a hanging indent")
        XCTAssertEqual(w?.ruleRows, 1, "header + 1 data row → exactly 1 row-separator rule")

        // A table that fits keeps the plain 12/12 inset — no hanging indent, identical to before.
        let narrow = """
        | A | B |
        |---|---|
        | x | y |
        """
        let n = probe(narrow)
        XCTAssertNotNil(n, "narrow table should produce a grid")
        XCTAssertEqual(n?.hang ?? -1, 0, accuracy: 0.5, "a fitting table keeps headIndent == firstLineHeadIndent")
    }

    // MARK: Table rendering — a wide NON-last column shrinks the whole table to fit (the last-column wrap
    // can't help when the overflow isn't in the last column). Locks the shrink-to-fit branch: a fitting
    // table keeps the full base font; an over-wide middle column scales down enough to GUARANTEE fit
    // (only a microscopic-text backstop floors the scale, so fitting always wins over a legibility floor).

    func testTableShrink_wideNonLastColumn_scalesDownFloored() {
        // Pin a narrow container (as in the wrap test) so the overflow decision is deterministic headlessly.
        let tv = MarkdownTextView(frame: CGRect(x: 0, y: 0, width: 360, height: 300))
        tv.textContainer?.size = NSSize(width: 360, height: 100_000)
        let vm = EditorViewModel(textView: tv)

        // The table's base font point size (read off the first table glyph) — 15 when it fits, smaller when
        // it had to shrink to fit a wide column that isn't last.
        func fontSize(_ s: String) -> CGFloat? {
            tv.string = s
            vm.refresh()
            guard let grid = tv.tableGrids.first,
                  let f = tv.textStorage?.attribute(.font, at: grid.blockRange.location,
                                                    effectiveRange: nil) as? NSFont else { return nil }
            return f.pointSize
        }

        // A long MIDDLE column (last column short) can't fit 360pt and the last-column wrap can't help, so
        // the whole table scales down.
        let wideMiddle = """
        | A | 설명 | B |
        |---|------|---|
        | x | 셀 폭만으로 창을 넘겨버리는 가운데 열의 제법 긴 설명 텍스트입니다 | y |
        | x | 짧음 | y |
        """
        let shrunk = fontSize(wideMiddle)
        XCTAssertNotNil(shrunk, "wide-middle table should produce a grid")
        XCTAssertLessThan(shrunk ?? 99, 15, "a wide non-last column must shrink the table below the 15pt base")
        XCTAssertGreaterThanOrEqual(shrunk ?? 0, 15 * 0.35 - 0.1, "shrink floored only by a 0.35× microscopic-text backstop")

        // PREFER WRAP over shrink: a wide middle column whose LAST column can still wrap into the remaining
        // space must NOT shrink — the row wraps at full size instead (shrinking would make the readable
        // columns tiny). Widen the container so the non-last columns fit and only the last column wraps.
        tv.textContainer?.size = NSSize(width: 620, height: 100_000)
        let wideMiddleWrappableLast = """
        | 코드 | number 는 IEEE 754 double 로 해석되어 정밀도가 손실됨 | 문자열로 전송하는 것이 안전한 관례입니다 |
        |---|---|---|
        | E1 | 짧음 | 짧음 |
        """
        XCTAssertEqual(fontSize(wideMiddleWrappableLast) ?? 0, 15, accuracy: 0.01,
                       "a wide middle column whose last column can wrap should wrap at full size, not shrink")

        // A table that fits keeps the full 15pt base — no shrink. (Back to the narrow container.)
        tv.textContainer?.size = NSSize(width: 360, height: 100_000)
        let fits = """
        | A | B |
        |---|---|
        | x | y |
        """
        XCTAssertEqual(fontSize(fits) ?? 0, 15, accuracy: 0.01, "a fitting table keeps the 15pt base font")
    }

    // MARK: Table rendering — INVARIANT: no table overflows the window. However its columns are sized, the
    // styled table must fit — by full-size layout, by wrapping its last column ON-SCREEN, or by shrinking —
    // never pushing a column off the right edge (which makes a row wrap to the margin and breaks the grid).
    // This is the whole point of the wrap + shrink paths; lock it across a matrix of shapes and widths.

    func testTableNeverOverflows_acrossShapesAndWidths() {
        let tv = MarkdownTextView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let vm = EditorViewModel(textView: tv)
        let inset: CGFloat = 12   // == TableRendering.tableInset

        // The table's effective right-edge need vs the usable width. When wrapping (headIndent > inset) the
        // last column starts at lastColLeftX and flows into the remainder, so it must start on-screen; when
        // not wrapping the whole laid-out width must fit. need ≤ avail ⇒ no overflow / no margin-wrap.
        func check(_ s: String, _ containerWidth: CGFloat) {
            tv.textContainer?.size = NSSize(width: containerWidth, height: 100_000)
            tv.string = s
            vm.refresh()
            guard let grid = tv.tableGrids.first,
                  let p = tv.textStorage?.attribute(.paragraphStyle, at: grid.blockRange.location,
                                                    effectiveRange: nil) as? NSParagraphStyle else {
                return XCTFail("no grid @\(Int(containerWidth))pt")
            }
            let pad = (tv.textContainer?.lineFragmentPadding ?? 5) * 2
            let avail = containerWidth - pad - inset
            let wrapping = p.headIndent > inset + 0.5
            let need = wrapping ? (p.headIndent - inset) : grid.totalWidth
            XCTAssertLessThanOrEqual(need, avail + 2,
                "@\(Int(containerWidth))pt overflows: need \(Int(need)) > avail \(Int(avail)) (wrapping=\(wrapping))")
        }

        let shapes = [
            // long LAST column
            "| 항목 | 분류 | 마지막 열에 제법 긴 설명이 들어가 줄바꿈이 필요할 수 있는 경우입니다 |\n|---|---|---|\n| a | b | c |",
            // wide MIDDLE column, short last
            "| A | 가운데 열이 길어서 창을 넘길 수 있는 설명 텍스트가 들어갑니다 | B |\n|---|---|---|\n| x | y | z |",
            // dense 5-column table (the user's method-table shape)
            "| 메서드 | 의미 | 본문 | 안전(safe) | 멱등(idempotent) |\n|---|---|---|---|---|\n| GET | 조회 | 없음 | 예 | 예 |\n| DELETE | 삭제 | 보통 없음 | 아니오 | 예 |",
            // TWO wide non-last columns
            "| 코드 | 첫번째 설명 칸이 꽤 깁니다 | 두번째 설명 칸도 꽤 깁니다 | 끝 |\n|---|---|---|---|\n| E | a | b | c |",
        ]
        for shape in shapes {
            // Includes narrow widths (360/320) where a wide-non-last table needs < 0.6× to fit — the old
            // 0.6 legibility floor pushed its last column off-screen there; the guaranteed-fit scale doesn't.
            for w in [1200.0, 900.0, 700.0, 520.0, 420.0, 360.0, 320.0] as [CGFloat] { check(shape, w) }
        }
    }

}
