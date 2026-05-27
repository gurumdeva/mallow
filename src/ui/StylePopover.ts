import { UIState } from '../domain/UIState'
import { EditorController } from '../editor/EditorController'

type StyleAction =
  | 'h1' | 'h2' | 'h3' | 'p'
  | 'quote' | 'bullet' | 'numbered' | 'code' | 'hr'
  | 'bold' | 'italic' | 'strike' | 'inlinecode'

/**
 * 텍스트 스타일 팝오버. InfoPopover와 같은 다크 카드 톤.
 * 세 섹션으로 구성:
 *   - Heading: H1 / H2 / H3 / Body (paragraph)
 *   - Block:   Quote / Bullet / Numbered / Code block / Divider
 *   - Inline:  Bold / Italic / Strikethrough / Inline code
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
      // Heading
      case 'h1': this.editor.setHeading(1); break
      case 'h2': this.editor.setHeading(2); break
      case 'h3': this.editor.setHeading(3); break
      case 'p':  this.editor.setHeading(null); break
      // Block
      case 'quote':    this.editor.wrapBlockquote(); break
      case 'bullet':   this.editor.wrapBulletList(); break
      case 'numbered': this.editor.wrapOrderedList(); break
      case 'code':     this.editor.createCodeBlock(); break
      case 'hr':       this.editor.insertDivider(); break
      // Inline
      case 'bold':       this.editor.toggleBold(); break
      case 'italic':     this.editor.toggleItalic(); break
      case 'strike':     this.editor.toggleStrikethrough(); break
      case 'inlinecode': this.editor.toggleInlineCode(); break
    }
  }

  /**
   * 14px viewBox-24 lucide-style stroke icons로 통일.
   * 텍스트 라벨(H1·B·I·S 등) 대신 그래픽으로 표기하는 버튼은 여기서 SVG를 반환.
   */
  private icon(name: 'quote' | 'bullet' | 'numbered' | 'code' | 'hr' | 'inlinecode'): string {
    const common = 'width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"'
    switch (name) {
      case 'quote':
        // 따옴표 두 쌍
        return `<svg ${common}><path d="M3 21c3 0 7-1 7-8V5c0-1.25-.756-2.017-2-2H4c-1.25 0-2 .75-2 1.972V11c0 1.25.75 2 2 2 1 0 1 0 1 1v1c0 1-1 2-2 2s-1 .008-1 1.031V20c0 1 0 1 1 1z"/><path d="M15 21c3 0 7-1 7-8V5c0-1.25-.757-2.017-2-2h-4c-1.25 0-2 .75-2 1.972V11c0 1.25.75 2 2 2 .85 0 1 0 1 1v1c0 1-1 2-2 2s-1 .008-1 1.031V20c0 1 0 1 1 1z"/></svg>`
      case 'bullet':
        return `<svg ${common}><line x1="8" y1="6" x2="21" y2="6"/><line x1="8" y1="12" x2="21" y2="12"/><line x1="8" y1="18" x2="21" y2="18"/><line x1="3" y1="6" x2="3.01" y2="6"/><line x1="3" y1="12" x2="3.01" y2="12"/><line x1="3" y1="18" x2="3.01" y2="18"/></svg>`
      case 'numbered':
        return `<svg ${common}><line x1="10" y1="6" x2="21" y2="6"/><line x1="10" y1="12" x2="21" y2="12"/><line x1="10" y1="18" x2="21" y2="18"/><path d="M4 6h1v4"/><path d="M4 10h2"/><path d="M6 18H4c0-1 2-2 2-3s-1-1.5-2-1"/></svg>`
      case 'code':
        // 코드 블록 — </> 화살괄호 모양 (큰 코드 블록을 상징)
        return `<svg ${common}><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg>`
      case 'hr':
        return `<svg ${common}><line x1="3" y1="12" x2="21" y2="12"/></svg>`
      case 'inlinecode':
        // 인라인 코드 — 모노스페이스 박스 안의 짧은 텍스트(<>)를 표현해 코드 블록과 구분.
        return `<svg ${common}><rect x="3" y="6" width="18" height="12" rx="2"/><polyline points="14 10 17 12 14 14"/><polyline points="10 10 7 12 10 14"/></svg>`
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
      <div class="style-section-label">Block</div>
      <div class="style-grid style-grid-5">
        <button class="style-btn" data-action="quote" title="인용">${this.icon('quote')}</button>
        <button class="style-btn" data-action="bullet" title="목록">${this.icon('bullet')}</button>
        <button class="style-btn" data-action="numbered" title="번호 목록">${this.icon('numbered')}</button>
        <button class="style-btn" data-action="code" title="코드 블록">${this.icon('code')}</button>
        <button class="style-btn" data-action="hr" title="구분선">${this.icon('hr')}</button>
      </div>
      <div class="style-section-label">Inline</div>
      <div class="style-grid style-grid-4">
        <button class="style-btn" data-action="bold" title="굵게 (⌘B)"><b>B</b></button>
        <button class="style-btn" data-action="italic" title="기울임 (⌘I)"><i>I</i></button>
        <button class="style-btn" data-action="strike" title="취소선"><span class="style-btn-strike">S</span></button>
        <button class="style-btn" data-action="inlinecode" title="인라인 코드">${this.icon('inlinecode')}</button>
      </div>
    `
  }
}
