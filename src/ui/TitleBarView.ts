import { Document } from '../domain/Document'
import { UIState } from '../domain/UIState'

/**
 * 타이틀바 가운데 파일명 버튼을 그리고, 클릭/더블클릭 시 UIState 토글만 호출.
 * 자체 인스턴스 상태 없음.
 */
export class TitleBarView {
  private readonly btn: HTMLButtonElement

  constructor(
    private readonly doc: Document,
    private readonly uiState: UIState,
  ) {
    this.btn = document.getElementById('file-name') as HTMLButtonElement
    this.bindDom()
    this.doc.on('changed', () => this.render())
    this.render()
  }

  private bindDom(): void {
    const handler = (e: Event) => {
      e.stopPropagation()
      this.uiState.toggleFilenamePopover()
    }
    this.btn.addEventListener('click', handler)
    this.btn.addEventListener('dblclick', handler)
  }

  private render(): void {
    this.btn.textContent = this.doc.displayTitle
  }
}
