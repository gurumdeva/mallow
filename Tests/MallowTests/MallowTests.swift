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

    // MARK: Table rendering v2 (docs/plans/table-rendering-v2-hscroll.md) — ONE size for every table (never
    // shrink); a long LAST column wraps INSIDE its column bounded by a tailIndent; a table too wide for the
    // viewport keeps full size and the editor scrolls horizontally. The headless seam pins the text container
    // to stand in for the viewport (availableWidth = size.width − 2·padding − tableInset).

    /// Style `s` at viewport `w` and read the load-bearing outputs off the first table.
    private func tableProbe(_ tv: MarkdownTextView, _ vm: EditorViewModel, _ s: String, _ w: CGFloat)
        -> (font: CGFloat, headIndent: CGFloat, tailIndent: CGFloat, inset: CGFloat,
            totalWidth: CGFloat, rules: Int, container: CGFloat)? {
        tv.textContainer?.size = NSSize(width: w, height: 100_000)
        tv.string = s
        vm.refresh()
        guard let grid = tv.tableGrids.first, let storage = tv.textStorage,
              let f = storage.attribute(.font, at: grid.blockRange.location, effectiveRange: nil) as? NSFont,
              let p = storage.attribute(.paragraphStyle, at: grid.blockRange.location, effectiveRange: nil) as? NSParagraphStyle
        else { return nil }
        return (f.pointSize, p.headIndent, p.tailIndent, p.firstLineHeadIndent, grid.totalWidth,
                grid.rowStartChars.count, tv.textContainer?.size.width ?? 0)
    }

    // Every table renders at the 15pt base — a wide one scrolls, it never shrinks (fixes the "제각각" sizes).
    func testTableV2_everyTableRendersAtBaseSize() {
        let tv = MarkdownTextView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let vm = EditorViewModel(textView: tv)
        let tables = [
            "| A | B |\n|---|---|\n| x | y |",                                                                 // fits
            "| A | 가운데 열이 아주 길어 창을 넘겨버리는 긴 설명 텍스트입니다 정말 길게 | B |\n|---|---|---|\n| x | y | z |",     // wide middle
            "| 메서드 | 의미 | 본문 | 안전(safe) | 멱등(idempotent) |\n|---|---|---|---|---|\n| GET | 조회 | 없음 | 예 | 예 |", // dense 5-col
        ]
        for t in tables {
            for w in [340.0, 700.0, 1100.0] as [CGFloat] {
                XCTAssertEqual(tableProbe(tv, vm, t, w)?.font ?? 0, 15, accuracy: 0.01,
                               "every table renders at 15pt (never shrinks), at any viewport width")
            }
        }
    }

    // A table that fits: no wrap edge, plain inset, fits the viewport, container stays the viewport (no scroll).
    func testTableV2_fittingTable_plainAndUnscrolled() {
        let tv = MarkdownTextView(frame: CGRect(x: 0, y: 0, width: 700, height: 400))
        let vm = EditorViewModel(textView: tv)
        guard let p = tableProbe(tv, vm, "| 이름 | 나이 | 직업 |\n|---|---|---|\n| 권 | 30 | 개발자 |", 700) else { return XCTFail() }
        XCTAssertEqual(p.font, 15, accuracy: 0.01)
        XCTAssertEqual(p.tailIndent, 0, "a fitting table has no wrap edge")
        XCTAssertEqual(p.headIndent, p.inset, accuracy: 0.5, "a fitting table: no hanging indent")
        XCTAssertLessThanOrEqual(p.totalWidth, 678 + 1, "fits within the viewport (700 − 2·5 − 12)")
        XCTAssertEqual(p.container, 700, accuracy: 1, "container stays the viewport width ⇒ no horizontal scroll")
    }

    // A long LAST column wraps INSIDE its column, bounded by a tailIndent, at full size; the table still fits
    // the viewport (no h-scroll), and no line fragment spills past the wrap edge.
    func testTableV2_longLastColumn_wrapsBoundedByTailIndent() {
        let tv = MarkdownTextView(frame: CGRect(x: 0, y: 0, width: 700, height: 400))
        let vm = EditorViewModel(textView: tv)
        let s = "| 항목 | 분류 | 설명 |\n|---|---|---|\n| A | 상태 | 마지막 열에 아주 긴 설명이 들어가서 반드시 여러 줄로 줄바꿈되어야 하는 경우입니다 그리고 조금 더 길게 늘립니다 |"
        guard let p = tableProbe(tv, vm, s, 700) else { return XCTFail() }
        XCTAssertEqual(p.font, 15, accuracy: 0.01, "full size, not shrunk")
        XCTAssertGreaterThan(p.headIndent, p.inset + 1, "hanging indent at the last column's left edge")
        XCTAssertGreaterThan(p.tailIndent, p.headIndent + 1, "an explicit wrap edge to the right of the column start")
        XCTAssertLessThanOrEqual(p.totalWidth, 678 + 2, "wrapped table fits the viewport — no horizontal scroll")
        XCTAssertEqual(p.container, 700, accuracy: 1, "no container widening for a wrap")
        // The wrapped cell's glyphs stay within the tailIndent (bounded in-column), not sprawling right.
        if let lm = tv.layoutManager, let tc = tv.textContainer, let grid = tv.tableGrids.first {
            lm.ensureLayout(for: tc)
            var maxUsedX: CGFloat = 0
            lm.enumerateLineFragments(forGlyphRange: lm.glyphRange(forCharacterRange: grid.blockRange,
                                                                   actualCharacterRange: nil)) { _, used, _, _, _ in
                maxUsedX = max(maxUsedX, used.maxX)
            }
            XCTAssertLessThanOrEqual(maxUsedX, tc.lineFragmentPadding + p.tailIndent + 3, "no glyph spills past the wrap edge")
        }
    }

    // Wide NON-last columns can't fit the viewport → the table keeps full size and the container widens so the
    // editor scrolls horizontally (never shrinks, never wraps a middle column).
    func testTableV2_wideNonLastColumns_horizontalScroll() {
        let tv = MarkdownTextView(frame: CGRect(x: 0, y: 0, width: 460, height: 400))
        let vm = EditorViewModel(textView: tv)
        let s = "| 코드 | 첫번째로 꽤 긴 설명이 들어가는 열입니다 길게 | 두번째로 꽤 긴 설명이 들어가는 열입니다 길게 | 끝 |\n|---|---|---|---|\n| E | a | b | c |"
        guard let p = tableProbe(tv, vm, s, 460) else { return XCTFail() }   // viewport ⇒ availableWidth = 438
        XCTAssertEqual(p.font, 15, accuracy: 0.01, "full size — a wide table scrolls, never shrinks")
        XCTAssertGreaterThan(p.totalWidth, 438, "wider than the viewport ⇒ horizontal scroll")
        XCTAssertGreaterThan(p.container, 461, "the container widened past the viewport for the scroller")
    }

    // Many rows: exactly one horizontal separator rule per source row after the header.
    func testTableV2_manyRows_oneRulePerRow() {
        let tv = MarkdownTextView(frame: CGRect(x: 0, y: 0, width: 700, height: 400))
        let vm = EditorViewModel(textView: tv)
        let rows = (1...7).map { "| \($0) | 단계\($0) | 설명 |" }.joined(separator: "\n")
        guard let p = tableProbe(tv, vm, "| # | 단계 | 설명 |\n|---|---|---|\n" + rows, 700) else { return XCTFail() }
        XCTAssertEqual(p.rules, 7, "7 data rows → 7 separator rules (header excluded)")
    }

    // Every interior column rule sits with roughly EQUAL padding to the text on both sides (no cell kissing a
    // rule). Measures, per header-row rule, the nearest visible glyph on each side and asserts both a floor
    // and near-symmetry — the defect was ~16pt on one side, ~1.7pt on the other.
    func testTableV2_cellPaddingSymmetricAroundRules() {
        let tv = MarkdownTextView(frame: CGRect(x: 0, y: 0, width: 700, height: 400))
        let vm = EditorViewModel(textView: tv)
        tv.textContainer?.size = NSSize(width: 700, height: 100_000)
        // Header is the widest cell in every column, so the header row's content edges ARE the column edges
        // (the rule centres on a column's widest cell; a shorter cell just gets extra trailing space).
        tv.string = "| 헷갈림개념 | 두번째열 | 정리요약 |\n|---|---|---|\n| A | B | C |"
        vm.refresh()
        guard let grid = tv.tableGrids.first, let lm = tv.layoutManager, let tc = tv.textContainer
        else { return XCTFail("no table grid") }
        lm.ensureLayout(for: tc)
        let ns = tv.string as NSString
        let leftGlyph = lm.glyphRange(forCharacterRange: NSRange(location: grid.blockRange.location, length: 1),
                                      actualCharacterRange: nil)
        let leftX = lm.boundingRect(forGlyphRange: leftGlyph, in: tc).minX

        // Ink extents of the VISIBLE glyphs (skip spaces + the pipe-as-space) on the header row.
        // `boundingRect` includes a glyph's ADVANCE — for the cell's kerned last char that advance carries
        // the alignment padding (`.kern`), which is exactly the blank the rule is centred in. Subtract the
        // char's own kern so `maxX` means "where the drawn letter ends", not "where the padding ends".
        let firstNL = ns.range(of: "\n").location
        var ink: [(minX: CGFloat, maxX: CGFloat)] = []
        for i in 0 ..< firstNL {
            let ch = ns.character(at: i)
            if ch == 32 || ch == 124 { continue }   // space or '|'
            let g = lm.glyphRange(forCharacterRange: NSRange(location: i, length: 1), actualCharacterRange: nil)
            let r = lm.boundingRect(forGlyphRange: g, in: tc)
            let kern = (tv.textStorage?.attribute(.kern, at: i, effectiveRange: nil) as? CGFloat) ?? 0
            ink.append((r.minX, r.maxX - kern))
        }
        XCTAssertFalse(grid.interiorEdges.isEmpty, "a 3-col table has interior rules")
        for edge in grid.interiorEdges {
            let x = leftX + edge
            let leftEnd = ink.filter { $0.maxX <= x + 0.5 }.map(\.maxX).max()
            let rightStart = ink.filter { $0.minX >= x - 0.5 }.map(\.minX).min()
            guard let l = leftEnd, let r = rightStart else { return XCTFail("rule has content on both sides") }
            let leftPad = x - l, rightPad = r - x
            XCTAssertGreaterThan(leftPad, 4, "rule \(edge): left padding too tight (\(leftPad))")
            XCTAssertGreaterThan(rightPad, 4, "rule \(edge): right padding too tight (\(rightPad))")
            XCTAssertLessThan(abs(leftPad - rightPad), 3, "rule \(edge): padding not symmetric (\(leftPad) vs \(rightPad))")
        }
    }

    // Hidden syntax markers are truly ZERO-WIDTH in layout, not just invisible. Regression for the
    // ghost-advance bug: `.null`-property glyphs kept their font advances, so backticks widened every
    // inline-code pill by ~2 characters, `**` left holes around bold text, `# ` indented headings off
    // the margin, and table cells containing markers drifted off their measured column slots.
    // (Requires the EditorLayoutDelegate — installed by EditorViewModel.init — to run headless.)
    func testHiddenMarkers_zeroWidthInLayout() {
        let tv = MarkdownTextView(frame: CGRect(x: 0, y: 0, width: 700, height: 400))
        let vm = EditorViewModel(textView: tv)
        tv.textContainer?.size = NSSize(width: 700, height: 100_000)
        tv.string = "# 헤딩\n\n본문 시작줄\n\n가 **볼드** 나\n\n가 `code` 나\n"
        vm.refresh()
        guard let lm = tv.layoutManager, let tc = tv.textContainer else { return XCTFail() }
        lm.ensureLayout(for: tc)
        let ns = tv.string as NSString
        func x(_ i: Int) -> CGFloat {
            let g = lm.glyphRange(forCharacterRange: NSRange(location: i, length: 1), actualCharacterRange: nil)
            return lm.location(forGlyphAt: g.location).x
        }
        // Heading text starts at the same x as body text (the hidden `# ` takes no space).
        XCTAssertEqual(x(2), x(ns.range(of: "본문").location), accuracy: 0.5, "heading aligns with body")
        // Bold text starts where its opening `**` starts (markers widthless).
        let boldOpen = ns.range(of: "**볼드**").location
        XCTAssertEqual(x(boldOpen + 2), x(boldOpen), accuracy: 0.5, "no ghost gap before bold text")
        // Inline code: both backticks widthless → the pill's box hugs the visible text.
        let tickOpen = ns.range(of: "`code`").location
        XCTAssertEqual(x(tickOpen + 1), x(tickOpen), accuracy: 0.5, "no ghost gap at the code span's left")
        XCTAssertEqual(x(tickOpen + 6), x(tickOpen + 5), accuracy: 0.5, "no ghost gap at the code span's right")
    }

    // MARK: - contract-pinning tests (from the modifiability review)

    // C2/C3: a table whose cells contain hidden markers (bold/code/link) still aligns its columns — the
    // measurement pass (visible width, hidden markers dropped) matches the render (zero-advance markers),
    // and recomputeHidden ran BEFORE restyle (the refresh() ordering). No prior test had marked-up cells,
    // so a pipeline reorder or a render/measure desync shipped green.
    func testContract_markedUpTableCells_columnsStayAligned() {
        let tv = MarkdownTextView(frame: CGRect(x: 0, y: 0, width: 700, height: 400))
        let vm = EditorViewModel(textView: tv)
        tv.textContainer?.size = NSSize(width: 700, height: 100_000)
        // Header widest per column (so header edges ARE the column edges); marked-up cells below.
        tv.string = "| 첫번째열헤더 | 두번째열헤더 |\n|---|---|\n| **볼드텍스트** | `codespan` |\n| [링크](https://e.com) | 평문 |"
        vm.refresh()
        guard let grid = tv.tableGrids.first, let lm = tv.layoutManager, let tc = tv.textContainer
        else { return XCTFail("no grid") }
        lm.ensureLayout(for: tc)
        let ns = tv.string as NSString
        let leftG = lm.glyphRange(forCharacterRange: NSRange(location: grid.blockRange.location, length: 1),
                                  actualCharacterRange: nil)
        let leftX = lm.boundingRect(forGlyphRange: leftG, in: tc).minX
        XCTAssertEqual(grid.interiorEdges.count, 1)
        let ruleX = leftX + grid.interiorEdges[0]
        // Every row's SECOND cell must start right of the rule with sane padding — if a marked-up first
        // cell mis-measured (render/measure desync), its row's second cell drifts off the rule.
        var lineStart = 0
        var rowIdx = 0
        while lineStart < ns.length {
            let line = ns.lineRange(for: NSRange(location: lineStart, length: 0))
            defer { lineStart = line.location + line.length; rowIdx += 1 }
            if rowIdx == 1 { continue }   // delimiter row (collapsed)
            // first visible ink RIGHT of the rule on this line
            var minRight = CGFloat.greatestFiniteMagnitude
            for i in line.location ..< (line.location + line.length) {
                let ch = ns.character(at: i)
                if ch == 32 || ch == 124 || ch == 10 || vm.hiddenChars.contains(i) { continue }
                let g = lm.glyphRange(forCharacterRange: NSRange(location: i, length: 1), actualCharacterRange: nil)
                let r = lm.boundingRect(forGlyphRange: g, in: tc)
                if r.minX >= ruleX - 0.5 { minRight = min(minRight, r.minX) }
            }
            guard minRight < .greatestFiniteMagnitude else { continue }
            let pad = minRight - ruleX
            XCTAssertGreaterThan(pad, 4, "row \(rowIdx): second cell too close to the rule (\(pad))")
            XCTAssertLessThan(pad, 14, "row \(rowIdx): second cell drifted off the rule (\(pad)) — measure/render desync")
        }
    }

    // C8: restyle is idempotent — the base pass's full-range setAttributes WIPES last pass's .kern before
    // this pass measures, so re-running restyle must yield identical table geometry. An "optimization"
    // that switches the wipe to targeted addAttribute calls would compound kern per pass and fail here.
    func testContract_restyleIsIdempotent_tableGeometryStable() {
        let tv = MarkdownTextView(frame: CGRect(x: 0, y: 0, width: 700, height: 400))
        let vm = EditorViewModel(textView: tv)
        tv.textContainer?.size = NSSize(width: 700, height: 100_000)
        tv.string = "| 헷갈림 | 정리 |\n|---|---|\n| 401 vs 403 | 인증 vs 인가 |"
        vm.refresh()
        guard let first = tv.tableGrids.first else { return XCTFail() }
        let w1 = first.totalWidth, e1 = first.interiorEdges
        vm.restyle()   // second pass over the SAME text
        vm.restyle()   // and a third
        guard let after = tv.tableGrids.first else { return XCTFail() }
        XCTAssertEqual(after.totalWidth, w1, accuracy: 0.01, "totalWidth drifted across restyles (stale kern?)")
        XCTAssertEqual(after.interiorEdges.count, e1.count)
        for (a, b) in zip(after.interiorEdges, e1) {
            XCTAssertEqual(a, b, accuracy: 0.01, "rule offset drifted across restyles")
        }
    }

    // C11: the zoom partition is a DESIGN DECISION made executable — body/heading/inline-code scale with
    // zoom; the table font deliberately stays fixed (its geometry is zoom-naive). If someone "fixes"
    // table zoom, this test forces them to do it deliberately (and completely), not by accident.
    func testContract_zoomPartition_scaledAndFixedSizes() {
        let tv = MarkdownTextView(frame: CGRect(x: 0, y: 0, width: 700, height: 400))
        let vm = EditorViewModel(textView: tv)
        tv.textContainer?.size = NSSize(width: 700, height: 100_000)
        tv.string = "# 헤딩\n\n본문 `code` 텍스트\n\n| 열 | 값 |\n|---|---|\n| A | B |"
        vm.zoomFactor = 1.5
        vm.refresh()
        guard let storage = tv.textStorage else { return XCTFail() }
        let ns = tv.string as NSString
        func fontAt(_ i: Int) -> CGFloat {
            (storage.attribute(.font, at: i, effectiveRange: nil) as? NSFont)?.pointSize ?? -1
        }
        XCTAssertEqual(fontAt(ns.range(of: "헤딩").location), 28 * 1.5, accuracy: 0.01, "H1 scales with zoom")
        XCTAssertEqual(fontAt(ns.range(of: "본문").location), mallowBodySize * 1.5, accuracy: 0.01, "body scales")
        XCTAssertEqual(fontAt(ns.range(of: "code").location), mallowBodySize * InlineCodeStyle.em * 1.5,
                       accuracy: 0.01, "inline code scales")
        XCTAssertEqual(fontAt(ns.range(of: "| A").location + 2), 15, accuracy: 0.01,
                       "table font is deliberately zoom-FIXED (change this test only with a complete table-zoom design)")
    }

    // C13: serde tag canary — the engine's block/inline kind and mark strings are matched as raw literals
    // across ~10 Swift sites, and unknown tags silently decode to "Other" (features just stop matching).
    // This pins the vocabulary: an inkstone enum rename now fails a test instead of blanking a feature.
    func testContract_serdeTagVocabulary_kitchenSink() {
        let doc = """
        # Heading

        Paragraph with **strong**, *emph*, `code`, ~~strike~~, and a [link](https://e.com).

        - list item

        > quoted

        ```
        fenced
        ```

        ---

        | a | b |
        |---|---|
        | 1 | 2 |
        """
        let blocks = inkParseBlocks(doc)
        let kinds = Set(blocks.map(\.kindTag))
        for expected in ["Heading", "Paragraph", "List", "BlockQuote", "CodeBlock", "ThematicBreak", "Table"] {
            XCTAssertTrue(kinds.contains(expected), "engine no longer emits kind '\(expected)' — renamed? Swift matches it as a literal")
        }
        XCTAssertFalse(kinds.contains("Other"), "some block decoded to 'Other' — the serde vocabulary drifted")
        let para = blocks.first { $0.kindTag == "Paragraph" }
        let marks = Set(para?.inlines.flatMap(\.marks) ?? [])
        for expected in ["Strong", "Emphasis", "Code", "Strikethrough"] {
            XCTAssertTrue(marks.contains(expected), "engine no longer emits mark '\(expected)'")
        }
        XCTAssertTrue(para?.inlines.contains { $0.kindTag == "Link" } ?? false, "engine no longer emits inline kind 'Link'")
        let table = blocks.first { $0.kindTag == "Table" }
        XCTAssertFalse(table?.cells.isEmpty ?? true, "table cells stopped decoding — serde shape drifted")
    }

}
