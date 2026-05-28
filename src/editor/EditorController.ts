import { Crepe, CrepeFeature } from '@milkdown/crepe'
import { commandsCtx, editorViewCtx } from '@milkdown/core'
import { toggleMark } from '@milkdown/prose/commands'
import { Plugin, PluginKey, TextSelection } from '@milkdown/prose/state'
import { Decoration, DecorationSet } from '@milkdown/prose/view'
import type { Node as ProseNode } from '@milkdown/prose/model'
import { replaceAll, $prose } from '@milkdown/utils'
import {
  setBlockTypeCommand,
  wrapInBlockquoteCommand,
  wrapInBulletListCommand,
  wrapInOrderedListCommand,
  createCodeBlockCommand,
  insertHrCommand,
  toggleInlineCodeCommand,
} from '@milkdown/preset-commonmark'
import { toggleStrikethroughCommand } from '@milkdown/preset-gfm'
import { EventEmitter } from '../domain/EventEmitter'
import { t } from '../i18n'

import '@milkdown/crepe/theme/common/style.css'
import '@milkdown/crepe/theme/frame-dark.css'

// ─── Find & Replace: ProseMirror 검색 플러그인 ──────────────────────
// prosemirror-search가 미설치라 커스텀 $prose 플러그인으로 구현한다(신규 의존성 0).
// 매치는 "텍스트 노드 단위"로 찾는다 → doc 위치가 항상 정확해 replace 시 텍스트가
// 어긋날 위험이 없다(마크 경계를 넘는 매치는 놓칠 수 있으나, 잘못된 치환보다 안전).
type SearchMatch = { from: number; to: number }
type SearchState = {
  query: string
  caseSensitive: boolean
  matches: SearchMatch[]
  current: number // matches 인덱스, 매치 없으면 -1
}

const searchKey = new PluginKey<SearchState>('mallow-search')

function computeSearchMatches(doc: ProseNode, query: string, caseSensitive: boolean): SearchMatch[] {
  if (!query) return []
  const out: SearchMatch[] = []
  const needle = caseSensitive ? query : query.toLowerCase()
  doc.descendants((node, pos) => {
    if (!node.isText || !node.text) return
    const hay = caseSensitive ? node.text : node.text.toLowerCase()
    let i = 0
    while ((i = hay.indexOf(needle, i)) !== -1) {
      out.push({ from: pos + i, to: pos + i + query.length })
      i += query.length
    }
  })
  return out
}

/** 검색 상태 + 하이라이트 decoration을 관리하는 ProseMirror 플러그인. */
const searchPlugin = $prose(
  () =>
    new Plugin<SearchState>({
      key: searchKey,
      state: {
        init: () => ({ query: '', caseSensitive: false, matches: [], current: -1 }),
        apply(tr, prev, _oldState, newState) {
          const meta = tr.getMeta(searchKey) as Partial<SearchState> | undefined
          if (meta) {
            const query = meta.query ?? prev.query
            const caseSensitive = meta.caseSensitive ?? prev.caseSensitive
            // query/대소문자가 바뀔 때만 재탐색(현재 인덱스만 바뀌면 재탐색 불필요).
            const rescan =
              (meta.query !== undefined && meta.query !== prev.query) ||
              (meta.caseSensitive !== undefined && meta.caseSensitive !== prev.caseSensitive)
            const matches = rescan
              ? computeSearchMatches(newState.doc, query, caseSensitive)
              : prev.matches
            let current = meta.current !== undefined ? meta.current : prev.current
            if (matches.length === 0) current = -1
            else if (current < 0 || current >= matches.length) current = 0
            return { query, caseSensitive, matches, current }
          }
          // 편집으로 doc이 바뀌면 매치를 다시 계산(위치 드리프트 방지).
          if (tr.docChanged && prev.query) {
            const matches = computeSearchMatches(newState.doc, prev.query, prev.caseSensitive)
            let current = prev.current
            if (matches.length === 0) current = -1
            else if (current >= matches.length) current = 0
            return { ...prev, matches, current }
          }
          return prev
        },
      },
      props: {
        decorations(state) {
          const s = searchKey.getState(state)
          if (!s || s.matches.length === 0) return DecorationSet.empty
          return DecorationSet.create(
            state.doc,
            s.matches.map((m, i) =>
              Decoration.inline(m.from, m.to, {
                class: i === s.current ? 'search-match search-match-current' : 'search-match',
              }),
            ),
          )
        },
      },
    }),
)

/**
 * Milkdown crepe 인스턴스 라이프사이클을 감싼다.
 * - initialize / load
 * - markdown 변경 시 'change' 이벤트 발행 (Crepe 공식 ListenerManager 사용)
 * - Document 같은 외부 객체는 직접 mutate하지 않음 (책임 분리)
 *
 * Crepe 공식 API 사용 원칙:
 *  - 변경 감지: `crepe.on(listener.markdownUpdated)` (raw DOM event 대신)
 *  - 컨텐츠 교체: `editor.action(replaceAll(md, true))` (destroy+recreate 대신)
 *  - 마크다운 추출: `crepe.getMarkdown()` (공식 public method)
 */
export class EditorController extends EventEmitter {
  private crepe: Crepe | null = null

  // load()에 의한 "프로그램적 콘텐츠 교체"가 사용자 편집('change')으로 잘못
  // 보고되지 않도록 다음 markdownUpdated 1회를 억제하는 플래그.
  // Milkdown listener는 markdownUpdated를 200ms debounce로 "비동기" 발화하므로,
  // load 직후 호출자가 동기로 markSaved()를 해도 나중에 도착한 이벤트가 doc을
  // 다시 dirty로 만든다. 그래서 markSaved 타이밍에 의존하지 않고 이벤트 자체를 억제한다.
  private suppressChange = false
  private suppressTimer: ReturnType<typeof setTimeout> | null = null

  constructor(private readonly rootSelector: string) {
    super()
  }

  async initialize(markdown: string): Promise<void> {
    this.crepe = this.createCrepe(markdown)
    // create() 전에 listener를 등록해야 초기 mount 후 변경부터 정확히 잡힌다.
    this.crepe.on((listener) => {
      listener.markdownUpdated(() => {
        if (this.suppressChange) {
          // 프로그램적 load가 유발한 이벤트 — 1회만 흡수하고 즉시 해제한다.
          this.clearSuppress()
          return
        }
        this.emit('change')
      })
    })
    await this.crepe.create()
  }

  /**
   * 컨텐츠 교체. Crepe 인스턴스는 유지하고 본문만 갈아끼운다.
   * flush=true: plugin/history state 초기화 (이전 문서의 undo 스택 등 제거).
   *
   * replaceAll은 debounce된 markdownUpdated를 한 번 유발하는데, 이는 사용자가
   * 친 게 아니라 프로그램이 갈아끼운 것이므로 'change' 발행을 억제한다.
   */
  async load(markdown: string): Promise<void> {
    if (!this.crepe) {
      await this.initialize(markdown)
      return
    }
    this.armSuppress()
    this.crepe.editor.action(replaceAll(markdown, true))
  }

  /** load 직후 도착할 markdownUpdated 1회를 억제 예약. */
  private armSuppress(): void {
    this.suppressChange = true
    if (this.suppressTimer) clearTimeout(this.suppressTimer)
    // 안전망: 새 내용이 기존과 동일하면(prevDoc.eq) markdownUpdated가 끝내
    // 발화하지 않아 플래그가 남는다. 그러면 다음 "진짜" 편집이 잘못 무시되므로
    // debounce(200ms)보다 충분히 긴 시간 뒤 강제 해제한다.
    this.suppressTimer = setTimeout(() => {
      this.suppressChange = false
      this.suppressTimer = null
    }, 500)
  }

  private clearSuppress(): void {
    this.suppressChange = false
    if (this.suppressTimer) {
      clearTimeout(this.suppressTimer)
      this.suppressTimer = null
    }
  }

  getMarkdown(): string {
    return this.crepe?.getMarkdown() ?? ''
  }

  // ─── Inline marks ───────────────────────────────────────────────
  // toggleBold/toggleItalic은 raw ProseMirror toggleMark가 가장 안정적.
  // schema.marks 이름은 commonmark preset의 strong / emphasis.

  toggleBold(): void {
    this.runOnView((view) => {
      const mark = view.state.schema.marks.strong
      if (mark) toggleMark(mark)(view.state, view.dispatch)
    })
  }

  toggleItalic(): void {
    this.runOnView((view) => {
      const mark = view.state.schema.marks.emphasis
      if (mark) toggleMark(mark)(view.state, view.dispatch)
    })
  }

  toggleStrikethrough(): void {
    this.callMilkdown(toggleStrikethroughCommand.key)
  }

  toggleInlineCode(): void {
    this.callMilkdown(toggleInlineCodeCommand.key)
  }

  // ─── Block transforms ────────────────────────────────────────────

  /**
   * level === null → paragraph (heading 해제).
   * Crepe의 setBlockTypeCommand는 applicability 체크를 거치지 않고
   * tr.setBlockType을 직접 호출해 heading↔paragraph 양방향 전환을 안정 지원한다.
   */
  setHeading(level: 1 | 2 | 3 | null): void {
    if (!this.crepe) return
    this.crepe.editor.action((ctx) => {
      const view = ctx.get(editorViewCtx)
      view.focus()
      const { schema } = view.state
      const nodeType = level === null ? schema.nodes.paragraph : schema.nodes.heading
      if (!nodeType) return
      ctx.get(commandsCtx).call(setBlockTypeCommand.key, {
        nodeType,
        attrs: level === null ? null : { level },
      })
    })
  }

  wrapBlockquote(): void { this.callMilkdown(wrapInBlockquoteCommand.key) }
  wrapBulletList(): void { this.callMilkdown(wrapInBulletListCommand.key) }
  wrapOrderedList(): void { this.callMilkdown(wrapInOrderedListCommand.key) }
  createCodeBlock(): void { this.callMilkdown(createCodeBlockCommand.key, '') }
  insertDivider(): void { this.callMilkdown(insertHrCommand.key) }

  // ─── Find & Replace ──────────────────────────────────────────────
  // 모든 검색 동작은 searchKey 플러그인 상태를 meta로 갱신하거나, 매치 위치로
  // selection을 옮겨 scrollIntoView한다. 입력창 포커스를 뺏지 않도록 view.focus()는
  // 호출하지 않는다(치환도 트랜잭션이라 포커스 없이 적용된다).

  /** 검색어/대소문자 설정. query가 비면 하이라이트가 사라진다. */
  setSearchQuery(query: string, caseSensitive: boolean): void {
    if (!this.crepe) return
    this.crepe.editor.action((ctx) => {
      const view = ctx.get(editorViewCtx)
      view.dispatch(
        view.state.tr.setMeta(searchKey, { query, caseSensitive, current: query ? 0 : -1 }),
      )
    })
    this.scrollToCurrentMatch()
  }

  /** 현재 매치 수/위치(1-based). UI의 "3 / 12" 라벨용. */
  searchInfo(): { current: number; total: number } {
    let info = { current: 0, total: 0 }
    this.crepe?.editor.action((ctx) => {
      const s = searchKey.getState(ctx.get(editorViewCtx).state)
      if (s) info = { current: s.matches.length ? s.current + 1 : 0, total: s.matches.length }
    })
    return info
  }

  searchNext(): void { this.stepSearch(1) }
  searchPrev(): void { this.stepSearch(-1) }

  private stepSearch(dir: 1 | -1): void {
    this.crepe?.editor.action((ctx) => {
      const view = ctx.get(editorViewCtx)
      const s = searchKey.getState(view.state)
      if (!s || s.matches.length === 0) return
      const next = (s.current + dir + s.matches.length) % s.matches.length
      const m = s.matches[next]
      view.dispatch(
        view.state.tr
          .setMeta(searchKey, { current: next })
          .setSelection(TextSelection.create(view.state.doc, m.from, m.to))
          .scrollIntoView(),
      )
    })
  }

  private scrollToCurrentMatch(): void {
    this.crepe?.editor.action((ctx) => {
      const view = ctx.get(editorViewCtx)
      const s = searchKey.getState(view.state)
      if (!s || s.current < 0 || !s.matches[s.current]) return
      const m = s.matches[s.current]
      view.dispatch(
        view.state.tr
          .setSelection(TextSelection.create(view.state.doc, m.from, m.to))
          .scrollIntoView(),
      )
    })
  }

  /**
   * 현재 매치를 치환하고 "다음 매치"로 이동한다. 치환으로 삽입된 텍스트가 검색어를
   * 포함하더라도(find "foo" → replace "foobar") 방금 넣은 구간은 건너뛰어,
   * 같은 자리를 무한히 다시 치환하는 일을 막는다.
   */
  searchReplace(replacement: string): void {
    if (!this.crepe) return
    this.crepe.editor.action((ctx) => {
      const view = ctx.get(editorViewCtx)
      const s = searchKey.getState(view.state)
      if (!s || s.current < 0 || !s.matches[s.current]) return
      const m = s.matches[s.current]
      const tr = view.state.tr
      if (replacement) tr.replaceWith(m.from, m.to, view.state.schema.text(replacement))
      else tr.delete(m.from, m.to)
      view.dispatch(tr) // docChanged → 매치 자동 재계산 (view.state 갱신됨)

      // 삽입한 텍스트 끝(after) 이후의 첫 매치로 이동(없으면 처음으로 wrap).
      const after = m.from + replacement.length
      const s2 = searchKey.getState(view.state)
      if (!s2 || s2.matches.length === 0) return
      let next = s2.matches.findIndex((mm) => mm.from >= after)
      if (next === -1) next = 0
      const nm = s2.matches[next]
      view.dispatch(
        view.state.tr
          .setMeta(searchKey, { current: next })
          .setSelection(TextSelection.create(view.state.doc, nm.from, nm.to))
          .scrollIntoView(),
      )
    })
  }

  /** 모든 매치를 한 번에 치환(끝→앞 순서로 앞쪽 위치 보존). */
  searchReplaceAll(replacement: string): void {
    this.crepe?.editor.action((ctx) => {
      const view = ctx.get(editorViewCtx)
      const s = searchKey.getState(view.state)
      if (!s || s.matches.length === 0) return
      const tr = view.state.tr
      for (let i = s.matches.length - 1; i >= 0; i--) {
        const m = s.matches[i]
        if (replacement) tr.replaceWith(m.from, m.to, view.state.schema.text(replacement))
        else tr.delete(m.from, m.to)
      }
      view.dispatch(tr)
    })
  }

  /** 검색 종료 — 하이라이트 제거. */
  clearSearch(): void {
    this.crepe?.editor.action((ctx) => {
      const view = ctx.get(editorViewCtx)
      view.dispatch(view.state.tr.setMeta(searchKey, { query: '', current: -1 }))
    })
  }

  // ─── Internal helpers ────────────────────────────────────────────

  /** ProseMirror view를 잡아 raw command를 dispatch. view.focus()로 selection 보호. */
  private runOnView(fn: (view: import('@milkdown/prose/view').EditorView) => void): void {
    if (!this.crepe) return
    this.crepe.editor.action((ctx) => {
      const view = ctx.get(editorViewCtx)
      view.focus()
      fn(view)
    })
  }

  /** Milkdown commandsCtx로 등록된 command를 호출. view.focus()를 묶어 호출 직전에 selection 회복. */
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  private callMilkdown(key: any, payload?: unknown): void {
    if (!this.crepe) return
    this.crepe.editor.action((ctx) => {
      ctx.get(editorViewCtx).focus()
      ctx.get(commandsCtx).call(key, payload)
    })
  }

  private createCrepe(markdown: string): Crepe {
    const crepe = new Crepe({
      root: this.rootSelector,
      defaultValue: markdown,
      features: {
        [CrepeFeature.Toolbar]: false,
      },
      featureConfigs: {
        [CrepeFeature.BlockEdit]: {
          blockHandle: { shouldShow: () => false },
        },
        // 빈 문서 placeholder를 기기 언어로. (Crepe 기본값은 "Please enter..." 영문)
        [CrepeFeature.Placeholder]: {
          text: t('editor.placeholder'),
        },
      },
    })
    // 찾기/바꾸기 검색 하이라이트 플러그인 등록(create() 전 — 기능 로드와 동일 경로).
    crepe.editor.use(searchPlugin)
    return crepe
  }
}
