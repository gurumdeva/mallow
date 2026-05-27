import { UIState } from '../domain/UIState'
import { EditorController } from '../editor/EditorController'

type StyleAction = 'h1' | 'h2' | 'h3' | 'p' | 'bold' | 'italic'

/**
 * 텍스트 스타일 팝오버. InfoPopover와 같은 다크 카드 톤으로,
 * Block 변환(H1/H2/H3/Body)과 Inline 마크(Bold/Italic)를 그리드로 표시한다.
 * 자체 상태 없음 — UIState.stylePopoverOpen만 read해서 표시 여부를 결정한다.
 */
export class StylePopover {
  private readonly popover: HTMLDivElement
  private readonly btn: HTMLButtonElement

  constructor(
    private readonly uiState: UIState,
    private readonly editor: EditorController,
  ) {
    this.popover = document.getElementById('style-popover') as HTMLDivElement
    this.btn = document.getElementById('btn-style') as HTMLButtonElement
    this.bindDom()
    this.uiState.on('changed', () => this.render())
    this.render()
  }

  private bindDom(): void {
    this.btn.addEventListener('click', (e) => {
      e.stopPropagation()
      this.uiState.toggleStylePopover()
    })
    this.popover.addEventListener('click', (e) => e.stopPropagation())
    document.addEventListener('click', (e) => {
      if (!this.uiState.stylePopoverOpen) return
      const t = e.target as Node
      if (this.popover.contains(t) || this.btn.contains(t)) return
      this.uiState.closeStylePopover()
    })
  }

  private render(): void {
    if (!this.uiState.stylePopoverOpen) {
      this.popover.classList.add('hidden')
      return
    }
    this.popover.classList.remove('hidden')
    this.popover.innerHTML = this.html()
    this.bindRenderedHandlers()
  }

  private bindRenderedHandlers(): void {
    this.popover.querySelectorAll<HTMLButtonElement>('.style-btn').forEach((b) => {
      // mousedown preventDefault: 버튼을 눌러도 ProseMirror가 focus/selection을
      // 잃지 않게 막는다. 안 하면 selection이 무너져서 toggleBold 등이 no-op이 된다.
      b.addEventListener('mousedown', (e) => e.preventDefault())
      b.addEventListener('click', (e) => {
        e.stopPropagation()
        const action = b.dataset.action as StyleAction | undefined
        if (!action) return
        this.apply(action)
      })
    })
  }

  private apply(action: StyleAction): void {
    switch (action) {
      case 'h1': this.editor.setHeading(1); break
      case 'h2': this.editor.setHeading(2); break
      case 'h3': this.editor.setHeading(3); break
      case 'p':  this.editor.setHeading(null); break
      case 'bold':   this.editor.toggleBold(); break
      case 'italic': this.editor.toggleItalic(); break
    }
  }

  private html(): string {
    return `
      <div class="stats-title">Style</div>
      <div class="style-section-label">Heading</div>
      <div class="style-grid style-grid-4">
        <button class="style-btn" data-action="h1" title="제목 1"><span class="style-btn-h1">H1</span></button>
        <button class="style-btn" data-action="h2" title="제목 2"><span class="style-btn-h2">H2</span></button>
        <button class="style-btn" data-action="h3" title="제목 3"><span class="style-btn-h3">H3</span></button>
        <button class="style-btn" data-action="p" title="본문"><span class="style-btn-body">Body</span></button>
      </div>
      <div class="style-section-label">Inline</div>
      <div class="style-grid style-grid-2">
        <button class="style-btn" data-action="bold" title="굵게 (⌘B)"><b>B</b></button>
        <button class="style-btn" data-action="italic" title="기울임 (⌘I)"><i>I</i></button>
      </div>
    `
  }
}
