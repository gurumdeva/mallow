// Localization — the app's i18n service (a Service-layer port of the Tauri `src/i18n`). The UI is
// internationalized to Korean / Japanese / English; the language is the DEVICE language, detected
// ONCE at launch from `Locale`, with English as the fallback (a single device-language decision —
// there is no in-app language switcher, matching the reference's `resolveLang`).
//
// `L.t(key)` looks a dot-path key up in the current language's table, falls back to English if the
// key is missing there, and finally returns the key itself so a typo is visible but never crashes
// (verbatim behavior of the reference `resolve()`). `L.t(key, ["name": …])` interpolates `{name}`
// placeholders the same way the reference `interpolate()` does — unknown placeholders are left in
// place so a missing value stands out instead of rendering "undefined".
//
// The string tables live in THIS file. The keys match the Tauri
// locale JSON 1:1 (menu.*, dialog.*, error.*, doc.*, editor.*, style.*, …) so the two stay in sync;
// the only native-only additions are `format.*` (the AppKit Format menu, which the web build renders
// as a Style popover instead) and `welcome.demo` (the launch document — the web build's welcome.ts).
//
// Wiring: the SwiftUI menu bar (`MallowCommands`) uses `L.t("menu.…")` / `L.t("format.…")` for its
// titles; the launch document (`demoMarkdown`) is `L.t("welcome.demo")`; and the alert helpers use
// `L.t("dialog.…")` / `L.t("error.…")`. The locale is resolved once at launch from the system language.

import Foundation

/// The three supported UI languages. `en` is the fallback for every other device language.
enum Lang: String {
    case en, ko, ja

    /// Normalize an OS locale identifier ("ko-KR", "ja_JP", "en-US", …) to a supported language:
    /// Korean → ko, Japanese → ja, everything else → en. Mirrors the reference `resolveLang`, which
    /// keys off the language prefix so regional variants (ko-KR, ja-JP) collapse to their language.
    static func resolve(_ raw: String?) -> Lang {
        let lower = (raw ?? "").lowercased()
        if lower.hasPrefix("ko") { return .ko }
        if lower.hasPrefix("ja") { return .ja }
        return .en
    }
}

/// The localization service. `L.current` is resolved once, lazily, from the device language; call
/// `L.t(_:)` (optionally with `{name}`-style params) to translate a dot-path key.
enum L {
    /// The active language — resolved ONCE from the device language at first access (launch).
    /// `Locale.preferredLanguages.first` is the user's top UI language ("ko", "ja-JP", "en-US", …);
    /// `Locale.current.identifier` is the fallback when that list is somehow empty.
    static let current: Lang = Lang.resolve(
        Locale.preferredLanguages.first ?? Locale.current.identifier
    )

    /// Translate `key` in the current language. Falls back to English, then to the raw key, so the
    /// call never returns nil and a missing key is visible (verbatim reference `resolve()` behavior).
    static func t(_ key: String) -> String {
        let table = tables[current] ?? en
        return table[key] ?? en[key] ?? key
    }

    /// Translate `key`, then substitute `{name}`-style placeholders from `params`. A placeholder with
    /// no matching param is left untouched so a missing value is conspicuous (reference `interpolate`).
    static func t(_ key: String, _ params: [String: String]) -> String {
        interpolate(t(key), params)
    }

    /// Replace each `{token}` in `template` with `params["token"]`; leave unmatched tokens in place.
    private static func interpolate(_ template: String, _ params: [String: String]) -> String {
        var out = template
        for (token, value) in params {
            out = out.replacingOccurrences(of: "{\(token)}", with: value)
        }
        return out
    }

    /// Lookup by language. `en` is also the fallback table inside `t(_:)`.
    private static let tables: [Lang: [String: String]] = [.en: en, .ko: ko, .ja: ja]

    // MARK: - String tables (keys match src/i18n/locales/*.json 1:1; format.* + welcome.* are native-only)

    private static let en: [String: String] = [
        // menu — the menu-bar titles + items wired in main.swift
        "menu.file": "File",
        "menu.edit": "Edit",
        "menu.format": "Format",
        "menu.view": "View",
        "menu.window": "Window",
        "menu.new": "New",
        "menu.open": "Open…",
        "menu.openRecent": "Open Recent",
        "menu.clearRecent": "Clear Menu",
        "recent.none": "No Recent Files",
        "menu.save": "Save",
        "menu.saveAs": "Save As…",
        "menu.exportPdf": "Export as PDF…",
        "menu.exportHtml": "Export as HTML…",
        "menu.close": "Close",
        "menu.focusMode": "Focus Mode",
        "menu.keepOnTop": "Keep on Top",
        "menu.typewriter": "Typewriter Scrolling",
        "menu.foldSections": "Fold All Sections",
        "menu.foldSection": "Fold Section",
        "menu.documentInfo": "Document Info",
        "menu.zoomIn": "Zoom In",
        "menu.zoomOut": "Zoom Out",
        "menu.actualSize": "Actual Size",
        "menu.quit": "Quit",
        "menu.undo": "Undo",
        "menu.redo": "Redo",
        "menu.cut": "Cut",
        "menu.copy": "Copy",
        "menu.paste": "Paste",
        "menu.pasteMatchStyle": "Paste and Match Style",
        "menu.copyRichText": "Copy as Rich Text",
        "menu.selectAll": "Select All",
        "menu.find": "Find…",
        "menu.findNext": "Find Next",
        "menu.findPrevious": "Find Previous",
        "menu.useSelectionForFind": "Use Selection for Find",
        // format — the AppKit Format menu (the web build's Style popover); titles + tips merged here
        "format.bold": "Bold",
        "format.italic": "Italic",
        "format.strikethrough": "Strikethrough",
        "format.inlineCode": "Inline Code",
        "format.h1": "Heading 1",
        "format.h2": "Heading 2",
        "format.h3": "Heading 3",
        "format.body": "Body",
        "format.bullet": "Bullet List",
        "format.numbered": "Numbered List",
        "format.quote": "Quote",
        "format.codeBlock": "Code Block",
        "format.divider": "Divider",
        // style — the Text-Style popover (the ✏️ corner button)
        "style.title": "Text Style",
        "style.headingSection": "Heading",
        "style.blockSection": "Block",
        "style.inlineSection": "Inline",
        // doc — derived document name
        "doc.untitled": "Untitled",
        // dialog — the unsaved-changes guard (confirmDiscardIfDirty)
        "dialog.discard.title": "Discard unsaved changes?",
        "dialog.discard.body": "The current document has edits that haven't been saved.",
        "dialog.discard.confirm": "Discard",
        "dialog.discard.cancel": "Cancel",
        // common buttons
        "common.ok": "OK",
        // error — alert titles surfaced from the controller's catch blocks
        "error.save": "Save",
        "error.exportPdf": "PDF Export",
        "error.exportHtml": "HTML Export",
        // info — the Document-Info popover (InfoPanel.swift): tabs, stat cards, units, TOC empty state
        "info.tab.statistics": "Statistics",
        "info.tab.contents": "Contents",
        "info.stat.words": "Words",
        "info.stat.characters": "Characters",
        "info.stat.paragraphs": "Paragraphs",
        "info.stat.readTime": "Read Time",
        "info.readMinuteUnit": "m",
        "info.meta.modified": "Modified",
        "info.toc.empty": "No headings to display.",
        // rename — the titlebar rename popover + its failure alert (RenameInTitlebar.swift)
        "rename.placeholder": "Filename",
        "rename.error.invalid.title": "Invalid file name",
        "rename.error.invalid.body": "A file name can't be empty or contain “/”.",
        "rename.error.exists.title": "A file with that name already exists",
        "rename.error.exists.body": "Choose a different name to avoid replacing the other file.",
        "rename.error.failed.title": "Couldn't rename the file",
        // image — the paste/drop image-embed error alerts (ImageInsert.swift)
        "image.error.tooLarge": "Image is too large (max 10 MB)",
        "image.error.failed": "Couldn't add the image",
        // reload — the external-change conflict prompt (ExternalReload.swift)
        "reload.title": "This file changed on disk. Reload?",
        "reload.body": "{name} was changed by another app. Reloading discards your unsaved edits.",
        "reload.confirm": "Reload",
        "reload.keepMine": "Keep Mine",
        // welcome — the launch document shown when no file is opened (AppDelegate.demoText)
        "welcome.demo": """
        # Inkstone

        A native macOS editor where **markdown is the source of truth** — parsed and
        styled live by a Rust engine, with the system IME for 한글 / 日本語.

        `#`, `**`, and `>` collapse away and return only on the caret's line. Try
        *italic*, ~~strikethrough~~, `inline code`, or a [link](https://example.com).

        ## Highlights
        - **Live styling** that never rewrites your text
        - Lists, quotes, and code rendered in place
        1. headings sized by level
        2. links, code, and rules

        > Markdown stays markdown — nothing is changed behind your back.

        The Format menu and ⌘B / ⌘I run the engine's commands; ⌘N / O / S handle files.
        """,
    ]

    private static let ko: [String: String] = [
        "menu.file": "파일",
        "menu.edit": "편집",
        "menu.format": "서식",
        "menu.view": "보기",
        "menu.window": "윈도우",
        "menu.new": "새로 만들기",
        "menu.open": "열기…",
        "menu.openRecent": "최근 파일 열기",
        "menu.clearRecent": "메뉴 지우기",
        "recent.none": "최근 파일 없음",
        "menu.save": "저장",
        "menu.saveAs": "다른 이름으로 저장…",
        "menu.exportPdf": "PDF로 내보내기…",
        "menu.exportHtml": "HTML로 내보내기…",
        "menu.close": "닫기",
        "menu.focusMode": "포커스 모드",
        "menu.keepOnTop": "항상 위에 표시",
        "menu.typewriter": "타이프라이터 스크롤",
        "menu.foldSections": "모든 섹션 접기",
        "menu.foldSection": "섹션 접기",
        "menu.documentInfo": "문서 정보",
        "menu.zoomIn": "확대",
        "menu.zoomOut": "축소",
        "menu.actualSize": "실제 크기",
        "menu.quit": "종료",
        "menu.undo": "실행 취소",
        "menu.redo": "실행 복귀",
        "menu.cut": "오려두기",
        "menu.copy": "복사하기",
        "menu.paste": "붙여넣기",
        "menu.pasteMatchStyle": "스타일에 맞춰 붙여넣기",
        "menu.copyRichText": "서식 있는 텍스트로 복사",
        "menu.selectAll": "전체 선택",
        "menu.find": "찾기…",
        "menu.findNext": "다음 찾기",
        "menu.findPrevious": "이전 찾기",
        "menu.useSelectionForFind": "선택 항목으로 찾기",
        "format.bold": "굵게",
        "format.italic": "기울임",
        "format.strikethrough": "취소선",
        "format.inlineCode": "인라인 코드",
        "format.h1": "제목 1",
        "format.h2": "제목 2",
        "format.h3": "제목 3",
        "format.body": "본문",
        "format.bullet": "목록",
        "format.numbered": "번호 목록",
        "format.quote": "인용",
        "format.codeBlock": "코드 블록",
        "format.divider": "구분선",
        "style.title": "텍스트 스타일",
        "style.headingSection": "제목",
        "style.blockSection": "블록",
        "style.inlineSection": "인라인",
        "doc.untitled": "제목 없음",
        "dialog.discard.title": "저장하지 않은 변경 사항을 무시할까요?",
        "dialog.discard.body": "현재 문서에 저장하지 않은 변경 사항이 있습니다.",
        "dialog.discard.confirm": "무시",
        "dialog.discard.cancel": "취소",
        "common.ok": "확인",
        "error.save": "저장",
        "error.exportPdf": "PDF 내보내기",
        "error.exportHtml": "HTML 내보내기",
        "info.tab.statistics": "통계",
        "info.tab.contents": "목차",
        "info.stat.words": "단어",
        "info.stat.characters": "글자",
        "info.stat.paragraphs": "문단",
        "info.stat.readTime": "읽기 시간",
        "info.readMinuteUnit": "분",
        "info.meta.modified": "수정한 날짜",
        "info.toc.empty": "표시할 제목이 없습니다.",
        "rename.placeholder": "파일 이름",
        "rename.error.invalid.title": "잘못된 파일 이름",
        "rename.error.invalid.body": "파일 이름은 비어 있거나 “/”를 포함할 수 없습니다.",
        "rename.error.exists.title": "같은 이름의 파일이 이미 있습니다",
        "rename.error.exists.body": "다른 파일을 덮어쓰지 않도록 다른 이름을 선택하세요.",
        "rename.error.failed.title": "파일 이름을 바꿀 수 없습니다",
        "image.error.tooLarge": "이미지가 너무 큽니다 (최대 10MB)",
        "image.error.failed": "이미지를 추가할 수 없습니다",
        "reload.title": "이 파일이 디스크에서 변경되었습니다. 다시 불러올까요?",
        "reload.body": "{name} 파일이 다른 앱에 의해 변경되었습니다. 다시 불러오면 저장하지 않은 변경 사항이 사라집니다.",
        "reload.confirm": "다시 불러오기",
        "reload.keepMine": "내 변경 사항 유지",
        "welcome.demo": """
        # Inkstone

        **마크다운이 원본**인 네이티브 macOS 에디터입니다. Rust 엔진이 실시간으로
        파싱·스타일링하며, 한글 / 日本語 입력을 위해 시스템 IME를 사용합니다.

        `#`, `**`, `>` 같은 기호는 사라졌다가 커서가 있는 줄에서만 다시 나타납니다.
        *기울임*, ~~취소선~~, `인라인 코드`, [링크](https://example.com)를 사용해 보세요.

        ## 주요 기능
        - 텍스트를 절대 다시 쓰지 않는 **실시간 스타일링**
        - 목록, 인용, 코드를 제자리에서 렌더링
        1. 레벨에 따라 크기가 정해지는 헤딩
        2. 링크, 코드, 구분선

        > 마크다운은 마크다운 그대로 — 뒤에서 아무것도 바뀌지 않습니다.

        서식 메뉴와 ⌘B / ⌘I는 엔진 명령을 실행하고, ⌘N / O / S는 파일을 다룹니다.
        """,
    ]

    private static let ja: [String: String] = [
        "menu.file": "ファイル",
        "menu.edit": "編集",
        "menu.format": "フォーマット",
        "menu.view": "表示",
        "menu.window": "ウインドウ",
        "menu.new": "新規",
        "menu.open": "開く…",
        "menu.openRecent": "最近使った項目を開く",
        "menu.clearRecent": "メニューを消去",
        "recent.none": "最近使った項目がありません",
        "menu.save": "保存",
        "menu.saveAs": "別名で保存…",
        "menu.exportPdf": "PDFで書き出す…",
        "menu.exportHtml": "HTMLで書き出す…",
        "menu.close": "閉じる",
        "menu.focusMode": "フォーカスモード",
        "menu.keepOnTop": "常に最前面に表示",
        "menu.typewriter": "タイプライタースクロール",
        "menu.foldSections": "すべてのセクションを折りたたむ",
        "menu.foldSection": "セクションを折りたたむ",
        "menu.documentInfo": "ドキュメント情報",
        "menu.zoomIn": "拡大",
        "menu.zoomOut": "縮小",
        "menu.actualSize": "実際のサイズ",
        "menu.quit": "終了",
        "menu.undo": "取り消す",
        "menu.redo": "やり直す",
        "menu.cut": "カット",
        "menu.copy": "コピー",
        "menu.paste": "ペースト",
        "menu.pasteMatchStyle": "ペーストしてスタイルを合わせる",
        "menu.copyRichText": "リッチテキストとしてコピー",
        "menu.selectAll": "すべてを選択",
        "menu.find": "検索…",
        "menu.findNext": "次を検索",
        "menu.findPrevious": "前を検索",
        "menu.useSelectionForFind": "選択部分を検索に使用",
        "format.bold": "太字",
        "format.italic": "斜体",
        "format.strikethrough": "取り消し線",
        "format.inlineCode": "インラインコード",
        "format.h1": "見出し1",
        "format.h2": "見出し2",
        "format.h3": "見出し3",
        "format.body": "本文",
        "format.bullet": "箇条書き",
        "format.numbered": "番号付きリスト",
        "format.quote": "引用",
        "format.codeBlock": "コードブロック",
        "format.divider": "区切り線",
        "style.title": "テキストスタイル",
        "style.headingSection": "見出し",
        "style.blockSection": "ブロック",
        "style.inlineSection": "インライン",
        "doc.untitled": "無題",
        "dialog.discard.title": "保存していない変更を破棄しますか？",
        "dialog.discard.body": "現在のドキュメントに保存されていない変更があります。",
        "dialog.discard.confirm": "破棄",
        "dialog.discard.cancel": "キャンセル",
        "common.ok": "OK",
        "error.save": "保存",
        "error.exportPdf": "PDF書き出し",
        "error.exportHtml": "HTML書き出し",
        "info.tab.statistics": "統計",
        "info.tab.contents": "目次",
        "info.stat.words": "単語",
        "info.stat.characters": "文字",
        "info.stat.paragraphs": "段落",
        "info.stat.readTime": "読了時間",
        "info.readMinuteUnit": "分",
        "info.meta.modified": "変更日",
        "info.toc.empty": "表示できる見出しがありません。",
        "rename.placeholder": "ファイル名",
        "rename.error.invalid.title": "無効なファイル名",
        "rename.error.invalid.body": "ファイル名を空にしたり「/」を含めることはできません。",
        "rename.error.exists.title": "同じ名前のファイルがすでにあります",
        "rename.error.exists.body": "ほかのファイルを置き換えないよう、別の名前を選んでください。",
        "rename.error.failed.title": "ファイル名を変更できませんでした",
        "image.error.tooLarge": "画像が大きすぎます（最大10MB）",
        "image.error.failed": "画像を追加できませんでした",
        "reload.title": "このファイルはディスク上で変更されました。再読み込みしますか？",
        "reload.body": "{name} はほかのアプリによって変更されました。再読み込みすると保存していない変更は破棄されます。",
        "reload.confirm": "再読み込み",
        "reload.keepMine": "自分の変更を保持",
        "welcome.demo": """
        # Inkstone

        **マークダウンが情報源**となるネイティブmacOSエディタです。Rustエンジンが
        リアルタイムに解析・スタイリングし、한글 / 日本語の入力にシステムIMEを使います。

        `#`、`**`、`>` などの記号は消え、カーソルのある行でのみ再表示されます。
        *斜体*、~~取り消し線~~、`インラインコード`、[リンク](https://example.com)をお試しください。

        ## 主な機能
        - テキストを決して書き換えない**リアルタイムスタイリング**
        - リスト、引用、コードをその場でレンダリング
        1. レベルに応じた大きさの見出し
        2. リンク、コード、区切り線

        > マークダウンはマークダウンのまま — 裏で何も変更されません。

        フォーマットメニューと⌘B / ⌘Iはエンジンのコマンドを実行し、⌘N / O / Sはファイルを扱います。
        """,
    ]
}
