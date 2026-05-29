import { UIState } from '../domain/UIState'
import { EditorController } from '../editor/EditorController'
import { t } from '../i18n'

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
    // 트리거 버튼의 팝오버 관계를 보조기술에 알린다(item 8). aria-expanded는 render에서 토글.
    this.btn.setAttribute('aria-haspopup', 'true')
    this.btn.setAttribute('aria-expanded', 'false')
    // #filename-popover와 동일하게 dialog로 노출(item 8).
    this.popover.setAttribute('role', 'dialog')
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
    // Esc로 닫기 — Find/Filename과 동작을 맞춘다(item 7). 열려 있을 때만 처리.
    document.addEventListener('keydown', (e) => {
      if (e.key === 'Escape' && this.uiState.stylePopoverOpen) {
        e.preventDefault()
        this.uiState.closeStylePopover()
      }
    })
  }

  private render(): void {
    const open = this.uiState.stylePopoverOpen
    this.btn.setAttribute('aria-expanded', open ? 'true' : 'false')
    if (!open) {
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
      <div class="stats-title">${t('style.title')}</div>
      <div class="style-section-label">${t('style.headingSection')}</div>
      <div class="style-grid style-grid-4">
        <button class="style-btn" data-action="h1" title="${t('style.tip.h1')}" aria-label="${t('style.tip.h1')}"><span class="style-btn-h1">H1</span></button>
        <button class="style-btn" data-action="h2" title="${t('style.tip.h2')}" aria-label="${t('style.tip.h2')}"><span class="style-btn-h2">H2</span></button>
        <button class="style-btn" data-action="h3" title="${t('style.tip.h3')}" aria-label="${t('style.tip.h3')}"><span class="style-btn-h3">H3</span></button>
        <button class="style-btn" data-action="p" title="${t('style.tip.body')}" aria-label="${t('style.tip.body')}"><span class="style-btn-body">${t('style.body')}</span></button>
      </div>
      <div class="style-section-label">${t('style.blockSection')}</div>
      <div class="style-grid style-grid-5">
        <button class="style-btn" data-action="quote" title="${t('style.tip.quote')}" aria-label="${t('style.tip.quote')}">${this.icon('quote')}</button>
        <button class="style-btn" data-action="bullet" title="${t('style.tip.bullet')}" aria-label="${t('style.tip.bullet')}">${this.icon('bullet')}</button>
        <button class="style-btn" data-action="numbered" title="${t('style.tip.numbered')}" aria-label="${t('style.tip.numbered')}">${this.icon('numbered')}</button>
        <button class="style-btn" data-action="code" title="${t('style.tip.code')}" aria-label="${t('style.tip.code')}">${this.icon('code')}</button>
        <button class="style-btn" data-action="hr" title="${t('style.tip.hr')}" aria-label="${t('style.tip.hr')}">${this.icon('hr')}</button>
      </div>
      <div class="style-section-label">${t('style.inlineSection')}</div>
      <div class="style-grid style-grid-4">
        <button class="style-btn" data-action="bold" title="${t('style.tip.bold')}" aria-label="${t('style.tip.bold')}"><b>B</b></button>
        <button class="style-btn" data-action="italic" title="${t('style.tip.italic')}" aria-label="${t('style.tip.italic')}"><i>I</i></button>
        <button class="style-btn" data-action="strike" title="${t('style.tip.strike')}" aria-label="${t('style.tip.strike')}"><span class="style-btn-strike">S</span></button>
        <button class="style-btn" data-action="inlinecode" title="${t('style.tip.inlineCode')}" aria-label="${t('style.tip.inlineCode')}">${this.icon('inlinecode')}</button>
      </div>
    `
  }
}
