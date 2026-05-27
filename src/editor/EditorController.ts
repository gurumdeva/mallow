import { Crepe, CrepeFeature } from '@milkdown/crepe'
import { commandsCtx } from '@milkdown/core'
import {
  toggleStrongCommand,
  toggleEmphasisCommand,
  wrapInHeadingCommand,
  downgradeHeadingCommand,
} from '@milkdown/preset-commonmark'
import { EventEmitter } from '../domain/EventEmitter'

import '@milkdown/crepe/theme/common/style.css'
import '@milkdown/crepe/theme/frame-dark.css'

// Crepe.create() 이후 ProseMirror DOM이 화면에 mount될 때까지 잠깐 대기하는 시간.
// 100ms는 경험적으로 충분한 값(M1 기준 즉시 mount되지만 안전 마진 포함).
const PROSEMIRROR_MOUNT_DELAY_MS = 100

/**
 * Milkdown crepe 인스턴스 라이프사이클을 감싼다.
 * - initialize / load (destroy + recreate)
 * - input/beforeinput 발생 시 'change' 이벤트 발행
 * - Document 같은 외부 객체를 직접 mutate하지 않음 (책임 분리)
 */
export class EditorController extends EventEmitter {
  private crepe: Crepe | null = null

  constructor(private readonly rootSelector: string) {
    super()
  }

  async initialize(markdown: string): Promise<void> {
    this.crepe = this.createCrepe(markdown)
    await this.crepe.create()
    this.attachChangeListener()
  }

  async load(markdown: string): Promise<void> {
    if (this.crepe) await this.crepe.destroy()
    this.crepe = this.createCrepe(markdown)
    await this.crepe.create()
    this.attachChangeListener()
  }

  getMarkdown(): string {
    try {
      // @ts-ignore Crepe runtime method
      return this.crepe?.getMarkdown() ?? ''
    } catch {
      return ''
    }
  }

  /**
   * Milkdown(ProseMirror) command를 직접 호출해 현재 selection에 Bold/Italic/Heading을 적용한다.
   * execCommand는 ProseMirror에서 일관되지 않아 commandsCtx 경로를 사용한다.
   * 적용 전 ProseMirror DOM에 focus를 줘서 selection이 유효하도록 만든다.
   */
  toggleBold(): void {
    if (!this.crepe) return
    this.focusEditor()
    this.crepe.editor.action((ctx) => {
      ctx.get(commandsCtx).call(toggleStrongCommand.key)
    })
    this.emit('change')
  }

  toggleItalic(): void {
    if (!this.crepe) return
    this.focusEditor()
    this.crepe.editor.action((ctx) => {
      ctx.get(commandsCtx).call(toggleEmphasisCommand.key)
    })
    this.emit('change')
  }

  /** level === null → paragraph(heading 해제). */
  setHeading(level: 1 | 2 | 3 | null): void {
    if (!this.crepe) return
    this.focusEditor()
    this.crepe.editor.action((ctx) => {
      const commands = ctx.get(commandsCtx)
      if (level === null) {
        commands.call(downgradeHeadingCommand.key)
      } else {
        commands.call(wrapInHeadingCommand.key, level)
      }
    })
    this.emit('change')
  }

  private focusEditor(): void {
    const pm = document.querySelector('.ProseMirror') as HTMLElement | null
    pm?.focus()
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

  private attachChangeListener(): void {
    setTimeout(() => {
      const pm = document.querySelector('.ProseMirror') as HTMLElement | null
      if (!pm) return
      const handler = () => this.emit('change')
      pm.addEventListener('input', handler)
      pm.addEventListener('beforeinput', handler)
    }, PROSEMIRROR_MOUNT_DELAY_MS)
  }
}
