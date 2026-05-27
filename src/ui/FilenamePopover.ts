import { Document } from '../domain/Document'
import { UIState } from '../domain/UIState'

/**
 * 파일명 편집 popover.
 * - open/close 상태는 UIState가 보유. 이 view는 그것을 read해서 표시 여부만 결정.
 * - 자체 인스턴스 상태 없음.
 */
export class FilenamePopover {
  private readonly popover: HTMLDivElement
  private readonly input: HTMLInputElement

  constructor(
    private readonly doc: Document,
    private readonly uiState: UIState,
  ) {
    this.popover = document.getElementById('filename-popover') as HTMLDivElement
    this.input = document.getElementById('filename-input') as HTMLInputElement
    this.bindDom()
    this.uiState.on('changed', () => this.render())
    this.render()
  }

  private bindDom(): void {
    this.input.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') {
        e.preventDefault()
        this.commit()
      } else if (e.key === 'Escape') {
        e.preventDefault()
        this.uiState.closeFilenamePopover()
      }
    })
    // popover 내부 클릭은 외부 클릭 핸들러에 잡히지 않도록 stopPropagation
    this.input.addEventListener('click', (e) => e.stopPropagation())
    this.popover.addEventListener('click', (e) => e.stopPropagation())

    document.addEventListener('click', (e) => {
      if (!this.uiState.filenamePopoverOpen) return
      const t = e.target as Node
      const btn = document.getElementById('file-name')
      if (this.popover.contains(t) || btn?.contains(t)) return
      this.commit()
    })
  }

  private commit(): void {
    this.doc.rename(this.input.value)
    this.uiState.closeFilenamePopover()
  }

  private render(): void {
    if (this.uiState.filenamePopoverOpen) {
      this.input.value = this.doc.filename
      this.popover.classList.remove('hidden')
      requestAnimationFrame(() => {
        this.input.focus()
        this.input.select()
      })
    } else {
      this.popover.classList.add('hidden')
    }
  }
}
