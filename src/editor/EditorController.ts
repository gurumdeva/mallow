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

  constructor(private readonly rootSelector: string) {
    super()
  }

  async initialize(markdown: string): Promise<void> {
    this.crepe = this.createCrepe(markdown)
    // create() 전에 listener를 등록해야 초기 mount 후 변경부터 정확히 잡힌다.
    this.crepe.on((listener) => {
      listener.markdownUpdated(() => this.emit('change'))
    })
    await this.crepe.create()
  }

  /**
   * 컨텐츠 교체. Crepe 인스턴스는 유지하고 본문만 갈아끼운다.
   * flush=true: plugin/history state 초기화 (이전 문서의 undo 스택 등 제거).
   */
  async load(markdown: string): Promise<void> {
    if (!this.crepe) {
      await this.initialize(markdown)
      return
    }
    this.crepe.editor.action(replaceAll(markdown, true))
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
