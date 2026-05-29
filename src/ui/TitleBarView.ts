import { Document } from '../domain/Document'
import { UIState } from '../domain/UIState'

/**
 * 타이틀바 가운데 파일명 버튼을 그리고, 클릭/더블클릭 시 UIState 토글만 호출.
 * 자체 인스턴스 상태 없음.
 */
export class TitleBarView {
  private readonly btn: HTMLButtonElement
  // ● 수정 표시는 너비가 고정된 별도 슬롯에 둔다. 텍스트에 직접 붙이면(● prefix)
  // 표시/숨김 시 가운데 정렬된 파일명이 가로로 흔들리므로(reflow), 슬롯의 가시성만 토글한다.
  private readonly dot: HTMLSpanElement
  private readonly nameEl: HTMLSpanElement

  constructor(
    private readonly doc: Document,
    private readonly uiState: UIState,
  ) {
    this.btn = document.getElementById('file-name') as HTMLButtonElement
    this.dot = document.createElement('span')
    this.dot.className = 'title-dot'
    this.dot.setAttribute('aria-hidden', 'true')
    this.dot.textContent = '●'
    this.nameEl = document.createElement('span')
    this.nameEl.className = 'title-name'
    this.btn.replaceChildren(this.dot, this.nameEl)
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
    // 파일명은 textContent로(임의 문자 안전), 수정 점은 클래스 토글로만 보였다 숨긴다.
    this.dot.classList.toggle('on', this.doc.isModified)
    this.nameEl.textContent = this.doc.filename
  }
}
