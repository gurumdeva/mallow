import { Crepe, CrepeFeature } from '@milkdown/crepe'
import { commandsCtx, editorViewCtx } from '@milkdown/core'
import { toggleMark } from '@milkdown/prose/commands'
import { replaceAll } from '@milkdown/utils'
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

import '@milkdown/crepe/theme/common/style.css'
import '@milkdown/crepe/theme/frame-dark.css'

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
    return new Crepe({
      root: this.rootSelector,
      defaultValue: markdown,
      features: {
        [CrepeFeature.Toolbar]: false,
      },
      featureConfigs: {
        [CrepeFeature.BlockEdit]: {
          blockHandle: { shouldShow: () => false },
        },
      },
    })
  }
}
