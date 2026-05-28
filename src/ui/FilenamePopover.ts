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
  /** 직전 render 시점에 팝업이 열려있었는지. closed→open transition에만 input.value를 채워 사용자 타이핑 보호. */
  private wasOpen = false

  /**
   * @param onCommit 사용자가 입력한 새 이름을 확정할 때 호출. 표시명만 바꿀지(새 문서)
   *   디스크 파일까지 rename할지(저장된 문서)는 호출부(FileService.applyRename)가 결정한다.
   */
  constructor(
    private readonly doc: Document,
    private readonly uiState: UIState,
    private readonly onCommit: (name: string) => void,
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
    this.onCommit(this.input.value)
    this.uiState.closeFilenamePopover()
  }

  private render(): void {
    const isOpen = this.uiState.filenamePopoverOpen
    if (isOpen) {
      // closed → open transition에만 input.value 초기화. 이미 열려있는 동안
      // doc/uiState 변경으로 render가 다시 불려도 사용자가 타이핑 중인 값을 덮지 않음.
      if (!this.wasOpen) {
        this.input.value = this.doc.filename
        this.popover.classList.remove('hidden')
        requestAnimationFrame(() => {
          this.input.focus()
          this.input.select()
        })
      }
    } else {
      this.popover.classList.add('hidden')
    }
    this.wasOpen = isOpen
  }
}
