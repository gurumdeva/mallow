import { EditorController } from '../editor/EditorController'
import { t } from '../i18n'

/**
 * 찾기/바꾸기 오버레이. ⌘F로 토글, Esc로 닫는다.
 * 자체 DOM을 body에 만들고 EditorController의 search* 메서드로 검색/치환을 구동한다.
 * 검색 상태는 에디터(ProseMirror 플러그인)가 들고, 이 뷰는 입력값 전달과 표시만 한다.
 */
export class FindReplace {
  private readonly root: HTMLDivElement
  private readonly findInput: HTMLInputElement
  private readonly replaceInput: HTMLInputElement
  private readonly countLabel: HTMLSpanElement
  private readonly caseBtn: HTMLButtonElement
  private caseSensitive = false
  private isOpen = false

  constructor(private readonly editor: EditorController) {
    this.root = document.createElement('div')
    this.root.id = 'find-replace'
    this.root.className = 'hidden'
    this.root.setAttribute('role', 'dialog')
    this.root.innerHTML = `
      <div class="find-row">
        <input class="find-input" type="text" autocomplete="off" spellcheck="false"
               placeholder="${attr(t('find.findPlaceholder'))}" aria-label="${attr(t('find.findPlaceholder'))}" />
        <span class="find-count" aria-live="polite"></span>
        <button class="find-btn" data-act="prev" title="${attr(t('find.previous'))}" type="button">↑</button>
        <button class="find-btn" data-act="next" title="${attr(t('find.next'))}" type="button">↓</button>
        <button class="find-btn find-case" data-act="case" title="${attr(t('find.matchCase'))}" type="button">Aa</button>
        <button class="find-btn" data-act="close" title="${attr(t('find.close'))}" type="button">✕</button>
      </div>
      <div class="find-row">
        <input class="replace-input" type="text" autocomplete="off" spellcheck="false"
               placeholder="${attr(t('find.replacePlaceholder'))}" aria-label="${attr(t('find.replacePlaceholder'))}" />
        <button class="find-btn find-text" data-act="replace" type="button">${esc(t('find.replace'))}</button>
        <button class="find-btn find-text" data-act="replaceAll" type="button">${esc(t('find.replaceAll'))}</button>
      </div>
    `
    document.body.appendChild(this.root)
    this.findInput = this.root.querySelector('.find-input') as HTMLInputElement
    this.replaceInput = this.root.querySelector('.replace-input') as HTMLInputElement
    this.countLabel = this.root.querySelector('.find-count') as HTMLSpanElement
    this.caseBtn = this.root.querySelector('.find-case') as HTMLButtonElement
    this.bind()
  }

  private bind(): void {
    this.findInput.addEventListener('input', () => this.runSearch())
    this.findInput.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') {
        e.preventDefault()
        if (e.shiftKey) this.editor.searchPrev()
        else this.editor.searchNext()
        this.refreshCount()
      } else if (e.key === 'Escape') {
        e.preventDefault()
        this.hide()
      }
    })
    this.replaceInput.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') {
        e.preventDefault()
        this.doReplace()
      } else if (e.key === 'Escape') {
        e.preventDefault()
        this.hide()
      }
    })
    this.root.addEventListener('click', (e) => {
      const btn = (e.target as HTMLElement).closest<HTMLElement>('.find-btn')
      if (!btn) return
      e.preventDefault()
      switch (btn.dataset.act) {
        case 'prev': this.editor.searchPrev(); this.refreshCount(); break
        case 'next': this.editor.searchNext(); this.refreshCount(); break
        case 'case': this.toggleCase(); break
        case 'close': this.hide(); break
        case 'replace': this.doReplace(); break
        case 'replaceAll': this.editor.searchReplaceAll(this.replaceInput.value); this.refreshCount(); break
      }
    })
  }

  private runSearch(): void {
    this.editor.setSearchQuery(this.findInput.value, this.caseSensitive)
    this.refreshCount()
  }

  private doReplace(): void {
    this.editor.searchReplace(this.replaceInput.value)
    this.refreshCount()
  }

  private toggleCase(): void {
    this.caseSensitive = !this.caseSensitive
    this.caseBtn.classList.toggle('active', this.caseSensitive)
    this.runSearch()
  }

  private refreshCount(): void {
    const { current, total } = this.editor.searchInfo()
    this.countLabel.textContent = total
      ? `${current}/${total}`
      : this.findInput.value
        ? '0/0'
        : ''
  }

  toggle(): void {
    if (this.isOpen) this.hide()
    else this.show()
  }

  show(): void {
    this.isOpen = true
    this.root.classList.remove('hidden')
    this.runSearch()
    requestAnimationFrame(() => {
      this.findInput.focus()
      this.findInput.select()
    })
  }

  hide(): void {
    if (!this.isOpen) return
    this.isOpen = false
    this.root.classList.add('hidden')
    this.editor.clearSearch()
  }
}

function esc(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}
function attr(s: string): string {
  return esc(s).replace(/"/g, '&quot;')
}
