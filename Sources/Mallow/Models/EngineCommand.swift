// EngineCommand — the canonical vocabulary of inkstone engine command strings the editor issues on the
// current selection. These nine strings were previously hand-copied across three files (StylePopover's
// style cards, MallowCommands' Format menu, and EditorViewModel+Commands' wrapping-command validation
// set); a typo in any copy compiled fine and shipped as a silent no-op. This enum is the single source:
// its raw value IS the command string passed over the FFI, so the menus and the VM reference cases —
// the compiler now rejects a misspelled command.
enum EngineCommand: String, CaseIterable {
    case toggleStrong = "toggle_strong"
    case toggleEmphasis = "toggle_emphasis"
    case toggleStrikethrough = "toggle_strikethrough"
    case toggleInlineCode = "toggle_inline_code"
    case toggleBlockquote = "toggle_blockquote"
    case toggleBulletList = "toggle_bullet_list"
    case toggleOrderedList = "toggle_ordered_list"
    case toggleCodeBlock = "toggle_code_block"
    case insertDivider = "insert_divider"

    /// Inline-mark toggles that WRAP the selection in a delimiter. On a bare caret these would wrap an
    /// empty selection — inserting a delimiter pair (`****`, `` `` ``) the parser can't see as a mark, so
    /// the hide-pass never collapses it and the raw markers SHOW (and persist in the saved file). For
    /// these, `apply(_:)` formats the WORD under the caret instead. (See EditorViewModel+Commands.)
    static let wrapping: Set<EngineCommand> =
        [.toggleStrong, .toggleEmphasis, .toggleStrikethrough, .toggleInlineCode]
}
