import { Crepe, CrepeFeature } from '@milkdown/crepe'
import { commandsCtx, editorViewCtx, editorViewOptionsCtx } from '@milkdown/core'
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
import { MAX_IMAGE_BYTES, imageFilesFrom, fileToDataURL } from './imageEmbed'
import { smartTypographyRules } from './smartTypographyRules'

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

// ─── Focus Mode: 캐럿이 있는 블록만 강조하는 플러그인 ────────────────
// 선택(selection)의 head가 속한 "최상위 블록"(doc의 직속 자식, depth 1)에 node decoration으로
// focus-active 클래스를 붙인다. 문장이 아니라 블록/단락 단위인 이유: 한국어·일본어는 문장 사이
// 띄어쓰기가 없어 문장 경계 추출이 불안정하므로 블록 단위가 옳다.
// 활성화 플래그는 plugin state에 두고 setMeta(focusKey, {enabled})로 토글한다. OFF면 decoration 없음.
type FocusState = { enabled: boolean }
const focusKey = new PluginKey<FocusState>('mallow-focus')

/** selection.head가 속한 최상위 블록의 [start, end) 위치. 없으면 null. */
function topBlockRange(state: import('@milkdown/prose/state').EditorState): { from: number; to: number } | null {
  const $head = state.selection.$head
  // depth 0은 doc 자신 — 감쌀 최상위 블록이 없으므로 제외한다.
  if ($head.depth === 0) return null
  // depth 1 = doc의 직속 자식(문단/제목/리스트/코드블록 등). before/after(1)로 그 노드 범위를 얻는다.
  return { from: $head.before(1), to: $head.after(1) }
}

/** Focus Mode decoration(현재 블록에 focus-active)을 관리하는 ProseMirror 플러그인. */
const focusPlugin = $prose(
  () =>
    new Plugin<FocusState>({
      key: focusKey,
      state: {
        init: () => ({ enabled: false }),
        apply(tr, prev) {
          const meta = tr.getMeta(focusKey) as Partial<FocusState> | undefined
          if (meta && meta.enabled !== undefined) return { enabled: meta.enabled }
          return prev
        },
      },
      props: {
        decorations(state) {
          const s = focusKey.getState(state)
          if (!s || !s.enabled) return DecorationSet.empty
          const range = topBlockRange(state)
          if (!range) return DecorationSet.empty
          // node decoration: 해당 블록 노드에 클래스를 부여 → CSS가 이 블록만 전체 불투명으로 복원.
          return DecorationSet.create(state.doc, [
            Decoration.node(range.from, range.to, { class: 'focus-active' }),
          ])
        },
      },
    }),
)

// ─── Typewriter Scrolling: 캐럿 줄을 화면 세로 중앙에 유지 ────────────
// ON이면 selection/doc 변경마다 coordsAtPos(head)로 캐럿 화면 좌표를 구해, 스크롤 컨테이너
// (#editor)를 그 줄이 뷰포트 50%에 오도록 스크롤한다. rAF로 한 프레임에 한 번만 반영(throttle).
// CJK(한국어/일본어) IME 조합 중에는 스크롤이 입력을 방해하므로 건너뛰고(view.composing),
// 조합이 끝나면(compositionend) 그때 한 번 보정한다.
// 활성화 여부는 컨트롤러가 소유한 holder를 통해 읽어, 에디터 재생성 없이 토글한다.
type TypewriterHolder = { enabled: boolean }

const typewriterPlugin = (holder: TypewriterHolder) =>
  $prose(
    () =>
      new Plugin({
        view: (view) => {
          let raf = 0
          // 스크롤 컨테이너: #editor(absolute + overflow-y:auto). ProseMirror DOM의 가장 가까운 조상.
          const scroller = (): HTMLElement | null =>
            (view.dom.closest('#editor') as HTMLElement | null) ?? null

          const center = (): void => {
            raf = 0
            if (!holder.enabled) return
            // 조합 중이면 보정하지 않는다(IME 후보창/커서 점프 방지). compositionend에서 처리.
            if (view.composing) return
            const el = scroller()
            if (!el) return
            let coords: { top: number; bottom: number }
            try {
              coords = view.coordsAtPos(view.state.selection.head)
            } catch {
              return // 위치가 일시적으로 무효(직후 doc 교체 등)면 조용히 건너뛴다
            }
            const rect = el.getBoundingClientRect()
            // 캐럿 줄의 화면상 중앙 y와 컨테이너 중앙의 차이만큼 스크롤을 이동시킨다.
            const caretMid = (coords.top + coords.bottom) / 2
            const targetMid = rect.top + rect.height / 2
            const delta = caretMid - targetMid
            if (Math.abs(delta) < 1) return // 이미 거의 중앙이면 흔들지 않는다
            el.scrollTop += delta
          }

          const schedule = (): void => {
            if (!holder.enabled) return
            if (raf) cancelAnimationFrame(raf)
            raf = requestAnimationFrame(center)
          }

          // 조합 종료 직후 한 번 중앙 보정(조합 중에는 건너뛰었으므로).
          const onCompositionEnd = (): void => schedule()
          view.dom.addEventListener('compositionend', onCompositionEnd)

          return {
            update: (_view, prevState) => {
              if (!holder.enabled) return
              // selection 또는 doc이 바뀐 경우에만 보정(decoration-only 변경엔 반응하지 않음).
              const moved =
                !prevState.selection.eq(view.state.selection) || !prevState.doc.eq(view.state.doc)
              if (moved) schedule()
            },
            destroy: () => {
              if (raf) cancelAnimationFrame(raf)
              view.dom.removeEventListener('compositionend', onCompositionEnd)
            },
          }
        },
      }),
  )

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

  // Typewriter 플러그인이 참조하는 활성화 holder. 에디터 재생성 없이 토글하기 위해
  // 객체로 들고 있다(플러그인은 같은 참조를 캡처). 매 실행 OFF로 시작(영속 없음).
  private readonly typewriterHolder: TypewriterHolder = { enabled: false }

  // Focus Mode 활성화 미러. load(flush=true)는 plugin state를 새로 init하므로 focus 플러그인의
  // enabled가 false로 풀린다 → 같은 창에서 파일을 in-place로 열면 디밍만 남고 강조 블록이 사라진다.
  // 이 미러로 load 직후 enabled를 다시 실어 그 회귀를 막는다. (typewriterHolder는 plugin state가
  // 아니라 컨트롤러 소유 객체라 flush의 영향을 받지 않으므로 별도 미러가 필요 없다.)
  private focusEnabled = false

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
    // flush=true는 EditorState를 새로 만들어 focus 플러그인의 enabled를 init값(false)으로
    // 되돌린다. Focus Mode가 켜진 채 in-place로 다른 파일을 열면 디밍만 남고 강조가 사라지므로,
    // 미러 상태가 ON이면 새 state에 enabled=true를 다시 실어준다.
    if (this.focusEnabled) this.setFocusMode(true)
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
  // 검색어 입력(setSearchQuery)은 하이라이트 decoration만 갱신하고, selection 이동·
  // scrollIntoView는 명시적 탐색(next/prev/Enter = stepSearch)·치환에서만 일어난다.
  // 입력창 포커스를 뺏지 않도록 view.focus()는 호출하지 않는다(치환도 트랜잭션이라
  // 포커스 없이 적용된다). 오버레이 진입/종료 시의 selection 보존은 뷰가 담당한다.

  /**
   * 검색어/대소문자 설정. query가 비면 하이라이트가 사라진다.
   * 하이라이트(decoration)만 갱신하고 selection/스크롤은 건드리지 않는다 —
   * 입력창에 한 글자 칠 때마다 문서가 스크롤되거나 선택이 옮겨지는 일을 막는다.
   * 실제 selection 이동은 next/prev/Enter에서만(stepSearch) 일어난다.
   */
  setSearchQuery(query: string, caseSensitive: boolean): void {
    if (!this.crepe) return
    this.crepe.editor.action((ctx) => {
      const view = ctx.get(editorViewCtx)
      view.dispatch(
        view.state.tr.setMeta(searchKey, { query, caseSensitive, current: query ? 0 : -1 }),
      )
    })
  }

  /** 현재 문서 selection의 평문(plain text). 오버레이가 열릴 때 찾기 입력 시드용(읽기 전용). */
  getSelectionText(): string {
    let text = ''
    this.crepe?.editor.action((ctx) => {
      const { state } = ctx.get(editorViewCtx)
      const { from, to } = state.selection
      if (from < to) text = state.doc.textBetween(from, to, '\n')
    })
    return text
  }

  /** 현재 selection 위치(오버레이 진입 시 저장 → 닫을 때 복원용). */
  getSelection(): { from: number; to: number } {
    let sel = { from: 0, to: 0 }
    this.crepe?.editor.action((ctx) => {
      const { selection } = ctx.get(editorViewCtx).state
      sel = { from: selection.from, to: selection.to }
    })
    return sel
  }

  /** 저장해 둔 selection을 복원한다(범위가 문서 밖이면 클램프). 검색 없이 오버레이를 닫을 때 사용. */
  restoreSelection(sel: { from: number; to: number }): void {
    this.crepe?.editor.action((ctx) => {
      const view = ctx.get(editorViewCtx)
      const size = view.state.doc.content.size
      const from = Math.min(Math.max(sel.from, 0), size)
      const to = Math.min(Math.max(sel.to, 0), size)
      view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, from, to)))
    })
  }

  /** ProseMirror view에 포커스를 준다. 찾기 오버레이를 닫을 때 에디터로 포커스를 되돌리는 데 사용. */
  focus(): void {
    this.crepe?.editor.action((ctx) => {
      ctx.get(editorViewCtx).focus()
    })
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

  /**
   * 현재 매치(인덱스 변경 없이)를 선택하고 뷰에 보이게 스크롤한다.
   * setSearchQuery는 입력 중 화면을 흔들지 않으려 스크롤하지 않으므로, 첫 탐색 시
   * "현재 매치(보통 0번)"를 건너뛰지 않고 그 위치를 드러내는 데 쓴다(첫 Next/Prev가
   * 1번/마지막으로 점프해 0번을 지나치는 문제 방지).
   */
  revealCurrentMatch(): void {
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
      if (replacement) {
        // 매치 시작 위치의 마크를 그대로 물려준다 → 굵게/기울임 등 안의 단어를
        // 치환해도 서식이 유지된다(plain text로 끼워 넣어 서식이 풀리는 일 방지).
        const marks = view.state.doc.resolve(m.from).marks()
        tr.replaceWith(m.from, m.to, view.state.schema.text(replacement, marks))
      } else tr.delete(m.from, m.to)
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

  /**
   * 모든 매치를 한 번에 치환(끝→앞 순서로 앞쪽 위치 보존). 치환한 개수를 반환한다.
   * searchReplace와 동일하게 각 매치 시작 위치의 마크를 물려줘 서식을 유지한다.
   */
  searchReplaceAll(replacement: string): number {
    let count = 0
    this.crepe?.editor.action((ctx) => {
      const view = ctx.get(editorViewCtx)
      const s = searchKey.getState(view.state)
      if (!s || s.matches.length === 0) return
      const tr = view.state.tr
      for (let i = s.matches.length - 1; i >= 0; i--) {
        const m = s.matches[i]
        if (replacement) {
          const marks = view.state.doc.resolve(m.from).marks()
          tr.replaceWith(m.from, m.to, view.state.schema.text(replacement, marks))
        } else tr.delete(m.from, m.to)
      }
      view.dispatch(tr)
      count = s.matches.length
    })
    return count
  }

  // ─── Focus Mode / Typewriter Scrolling ──────────────────────────
  // 둘 다 메뉴 토글로 켜고 끄는 독립 모드다. 상태는 영속하지 않으며(매 실행 OFF) 호출자가
  // 루트 클래스(focus-mode / typewriter-mode)도 함께 토글해 CSS(디밍·패딩·크롬 페이드)를 건다.

  /**
   * Focus Mode 토글. ON이면 focus 플러그인이 캐럿이 속한 최상위 블록에 focus-active
   * decoration을 붙인다(CSS가 그 블록만 불투명 복원). selection 보존을 위해 view.focus()는
   * 호출하지 않는다 — meta만 실어 가벼운 트랜잭션 1회 dispatch한다.
   */
  setFocusMode(on: boolean): void {
    this.focusEnabled = on
    this.crepe?.editor.action((ctx) => {
      const view = ctx.get(editorViewCtx)
      view.dispatch(view.state.tr.setMeta(focusKey, { enabled: on }))
    })
  }

  /**
   * Typewriter Scrolling 토글. holder 플래그만 바꾸면 플러그인이 다음 selection/doc
   * 변경부터 캐럿 줄을 중앙에 맞춘다. 켤 때는 즉시 한 번 중앙 정렬해 "지금 줄"이 바로
   * 가운데로 오게 한다(다음 입력을 기다리지 않음).
   */
  setTypewriter(on: boolean): void {
    this.typewriterHolder.enabled = on
    if (on) this.centerCaretNow()
  }

  /** 현재 캐럿 줄을 즉시 #editor 뷰포트 중앙으로 스크롤(typewriter ON 전환 시 1회). */
  private centerCaretNow(): void {
    this.crepe?.editor.action((ctx) => {
      const view = ctx.get(editorViewCtx)
      if (view.composing) return // 조합 중이면 건드리지 않는다(IME 보호)
      const el = view.dom.closest('#editor') as HTMLElement | null
      if (!el) return
      let coords: { top: number; bottom: number }
      try {
        coords = view.coordsAtPos(view.state.selection.head)
      } catch {
        return
      }
      const rect = el.getBoundingClientRect()
      const delta = (coords.top + coords.bottom) / 2 - (rect.top + rect.height / 2)
      if (Math.abs(delta) >= 1) el.scrollTop += delta
    })
  }

  /** 검색 종료 — 하이라이트 제거. */
  clearSearch(): void {
    this.crepe?.editor.action((ctx) => {
      const view = ctx.get(editorViewCtx)
      view.dispatch(view.state.tr.setMeta(searchKey, { query: '', current: -1 }))
    })
  }

  // ─── 이미지 붙여넣기 / 드래그-드롭 ───────────────────────────────
  // paste/drop된 이미지 파일을 data URI 인라인 이미지로 본문에 삽입한다.
  // FileReader가 비동기라 핸들러는 "처리함"(true)만 먼저 반환하고, 실제 삽입은
  // insertImageFiles에서 await로 진행한다. 실패 시 'imageerror'를 발행(상위가 토스트).

  /** paste/drop 핸들러를 제공하는 ProseMirror 플러그인. */
  private imageDropPastePlugin() {
    return $prose(
      () =>
        new Plugin({
          props: {
            handlePaste: (view, event) => this.onImagePaste(view, event),
            handleDrop: (view, event) => this.onImageDrop(view, event),
          },
        }),
    )
  }

  private onImagePaste(
    view: import('@milkdown/prose/view').EditorView,
    event: ClipboardEvent,
  ): boolean {
    const files = imageFilesFrom(event.clipboardData)
    if (files.length === 0) return false // 이미지가 없으면 기본 붙여넣기에 맡긴다
    event.preventDefault()
    void this.insertImageFiles(view, files)
    return true
  }

  private onImageDrop(
    view: import('@milkdown/prose/view').EditorView,
    event: DragEvent,
  ): boolean {
    const files = imageFilesFrom(event.dataTransfer)
    if (files.length === 0) return false // 내부 텍스트 이동 등은 기본 동작 유지
    const pos = view.posAtCoords({ left: event.clientX, top: event.clientY })?.pos
    event.preventDefault() // 브라우저가 드롭한 파일을 열어버리는 기본 동작 차단
    void this.insertImageFiles(view, files, pos)
    return true
  }

  /**
   * 이미지 파일들을 읽은 순서대로 data URI 인라인 이미지로 삽입한다.
   * dropPos가 있으면 첫 이미지는 그 위치에, 이후 이미지는 직전 삽입 위치 뒤에 이어 붙는다.
   */
  private async insertImageFiles(
    view: import('@milkdown/prose/view').EditorView,
    files: File[],
    dropPos?: number,
  ): Promise<void> {
    // 여러 파일을 드롭/붙여넣었을 때 파일마다 토스트를 띄우면 화면이 도배된다.
    // 사유별(너무 큼 / 읽기·삽입 실패) 횟수만 집계해 끝에서 사유당 1회만 알린다.
    let tooLarge = 0
    let failed = 0
    let first = true
    for (const file of files) {
      if (file.size > MAX_IMAGE_BYTES) {
        tooLarge++
        continue
      }
      let src: string
      try {
        src = await fileToDataURL(file)
      } catch {
        failed++
        continue
      }
      // 읽는 동안 창이 닫혔거나 에디터가 파괴됐으면 중단(dispatch가 throw하는 것 방지).
      const imageType = view.state.schema.nodes.image
      if (!this.crepe || !imageType) break
      try {
        let tr = view.state.tr
        if (dropPos != null && first) {
          const clamped = Math.min(Math.max(dropPos, 0), view.state.doc.content.size)
          tr = tr.setSelection(TextSelection.near(view.state.doc.resolve(clamped)))
        }
        // 파일명(확장자 제거)을 alt로 → 저장된 마크다운이 읽기 쉽고 접근성에도 좋다.
        const alt = file.name ? file.name.replace(/\.[^./\\]+$/, '') : ''
        tr = tr.replaceSelectionWith(imageType.create({ src, alt }), false)
        view.dispatch(tr)
        first = false
      } catch {
        failed++ // 스키마상 삽입 불가(예: 코드블록 내부) 등
      }
    }
    // 사유별 1회만 발행 — 상위(main.ts)가 사유에 맞는 토스트로 변환한다.
    if (tooLarge > 0) this.emit('imageerror', 'too-large')
    if (failed > 0) this.emit('imageerror', 'failed')
  }

  /**
   * Crepe 이미지 블록의 클릭/링크 업로드 경로용 onUpload. paste/drop과 동일하게
   * 용량 상한을 적용한다(이 가드가 없으면 업로드 UI로는 10MB 초과 이미지가 그대로 들어간다).
   * 화살표 필드로 둬서 featureConfig에 넘겨도 this 바인딩이 유지된다.
   */
  private uploadImage = async (file: File): Promise<string> => {
    if (file.size > MAX_IMAGE_BYTES) {
      this.emit('imageerror', 'too-large')
      throw new Error('image too large')
    }
    return fileToDataURL(file)
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
        // 이미지 블록의 클릭-업로드 UI: 업로드 결과를 data URI로(저장 후 깨지는 blob: URL 방지)
        // + 버튼/플레이스홀더 텍스트를 기기 언어로. (onUpload은 inline/block 양쪽 기본값에 적용)
        [CrepeFeature.ImageBlock]: {
          onUpload: this.uploadImage,
          inlineUploadButton: t('image.upload'),
          inlineUploadPlaceholderText: t('image.pasteLink'),
          blockUploadButton: t('image.uploadFile'),
          blockConfirmButton: t('image.confirm'),
          blockUploadPlaceholderText: t('image.pasteLink'),
          blockCaptionPlaceholderText: t('image.caption'),
        },
      },
    })
    // 네이티브 맞춤법 검사: ProseMirror contenteditable(.ProseMirror = view.dom)에 spellcheck="true"를
    // 건다. macOS WKWebView가 우클릭 교정 후보를 제공한다(빨간 밑줄은 안 나오지만 정상 — 별도 라이브러리 없음).
    // EditorView의 attributes editorProp은 view.dom 속성을 선언적으로 지정하는 공식 경로다.
    crepe.editor.config((ctx) => {
      ctx.update(editorViewOptionsCtx, (prev) => ({
        ...prev,
        attributes: { ...(prev.attributes as Record<string, string> | undefined), spellcheck: 'true' },
      }))
    })
    // 찾기/바꾸기 검색 하이라이트 플러그인 등록(create() 전 — 기능 로드와 동일 경로).
    crepe.editor.use(searchPlugin)
    // Focus Mode(현재 블록 강조) + Typewriter(캐럿 줄 중앙 유지) 플러그인 등록.
    // 둘 다 기본 OFF이며 setFocusMode/setTypewriter로 켜진다(검색 플러그인과 독립적으로 공존).
    crepe.editor.use(focusPlugin)
    crepe.editor.use(typewriterPlugin(this.typewriterHolder))
    // 스마트 타이포그래피 입력 규칙(따옴표/대시/줄임표). $inputRule이라 core의 단일 inputRules
    // 플러그인에 합쳐져 IME 보호·코드 제외·Backspace/⌘Z 되돌리기가 그대로 적용된다(기본 ON, 토글 없음).
    smartTypographyRules.forEach((rule) => crepe.editor.use(rule))
    // 이미지 paste/드래그-드롭 플러그인 등록.
    crepe.editor.use(this.imageDropPastePlugin())
    return crepe
  }
}
