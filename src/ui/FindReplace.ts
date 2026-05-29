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
  // 오버레이 진입 시점의 문서 selection. 탐색 없이 닫으면 이 위치로 되돌린다(item 4).
  private savedSelection: { from: number; to: number } | null = null
  // 이번 세션에서 next/prev/Enter/치환으로 selection을 실제로 옮겼는지.
  // 옮겼다면 닫을 때 원래 위치로 되돌리지 않는다(사용자가 도착한 매치를 보존).
  private navigated = false
  // 오버레이가 열린 동안 문서가 편집되면(비모달이라 본문 편집 가능) 저장해둔 selection
  // 위치가 어긋난다. 그 경우 닫을 때 원위치 복원을 건너뛴다(엉뚱한 곳으로 캐럿 이동 방지).
  private docDirty = false
  // "{n} replaced" 임시 라벨을 잠시 보여준 뒤 일반 카운트로 되돌리는 타이머(item 3).
  private replacedTimer: ReturnType<typeof setTimeout> | null = null

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
    // 오버레이가 열린 동안 사용자가 본문을 직접 편집하면 docDirty를 세운다(닫을 때 복원 가드).
    this.editor.on('change', () => {
      if (this.isOpen) this.docDirty = true
    })
    this.bind()
  }

  /**
   * 첫 탐색은 시드된 "현재 매치"(보통 0번)를 그대로 보여주고, 그 다음부터 next/prev로 이동한다.
   * (검색어 입력은 화면을 흔들지 않으므로, 첫 Next/Prev가 0번을 건너뛰지 않게 하기 위함)
   */
  private navigate(dir: 1 | -1): void {
    if (!this.navigated) this.editor.revealCurrentMatch()
    else if (dir === 1) this.editor.searchNext()
    else this.editor.searchPrev()
    this.navigated = true
    this.refreshCount()
  }

  private bind(): void {
    this.findInput.addEventListener('input', () => this.runSearch())
    this.findInput.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') {
        e.preventDefault()
        this.navigate(e.shiftKey ? -1 : 1)
      } else if (e.key === 'Escape') {
        e.preventDefault()
        e.stopPropagation() // Find의 Esc가 Style/Info 팝업 닫기 핸들러로 버블링되지 않게.
        this.hide()
      }
    })
    this.replaceInput.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') {
        e.preventDefault()
        this.doReplace()
      } else if (e.key === 'Escape') {
        e.preventDefault()
        e.stopPropagation()
        this.hide()
      }
    })
    this.root.addEventListener('click', (e) => {
      const btn = (e.target as HTMLElement).closest<HTMLElement>('.find-btn')
      if (!btn) return
      e.preventDefault()
      switch (btn.dataset.act) {
        case 'prev': this.navigate(-1); break
        case 'next': this.navigate(1); break
        case 'case': this.toggleCase(); break
        case 'close': this.hide(); break
        case 'replace': this.doReplace(); break
        case 'replaceAll': this.doReplaceAll(); break
      }
    })
  }

  private runSearch(): void {
    // 검색어를 다시 입력하면 "{n} replaced" 임시 표시는 의미가 없으므로 취소한다.
    if (this.replacedTimer) {
      clearTimeout(this.replacedTimer)
      this.replacedTimer = null
    }
    this.editor.setSearchQuery(this.findInput.value, this.caseSensitive)
    this.refreshCount()
  }

  private doReplace(): void {
    this.editor.searchReplace(this.replaceInput.value)
    this.navigated = true // 치환은 selection을 옮기므로 닫을 때 원위치 복원하지 않는다.
    this.refreshCount()
  }

  /** 모두 바꾸기 + 바꾼 개수를 카운트 영역에 잠시 표시(item 3). */
  private doReplaceAll(): void {
    const n = this.editor.searchReplaceAll(this.replaceInput.value)
    this.navigated = true
    if (n > 0) this.flashReplacedCount(n)
    else this.refreshCount()
  }

  /** "{n} replaced"를 잠깐 보여준 뒤 일반 카운트 표시로 되돌린다. */
  private flashReplacedCount(n: number): void {
    if (this.replacedTimer) clearTimeout(this.replacedTimer)
    this.countLabel.textContent = t('find.replacedCount', { n })
    this.replacedTimer = setTimeout(() => {
      this.replacedTimer = null
      this.refreshCount()
    }, 1500)
  }

  private toggleCase(): void {
    this.caseSensitive = !this.caseSensitive
    this.caseBtn.classList.toggle('active', this.caseSensitive)
    this.runSearch()
  }

  private refreshCount(): void {
    const { current, total } = this.editor.searchInfo()
    // 매치 있음 → "3/12", 검색어는 있는데 0건 → 지역화된 "결과 없음", 빈 검색어 → 빈 표시.
    this.countLabel.textContent = total
      ? `${current}/${total}`
      : this.findInput.value
        ? t('find.noResults')
        : ''
  }

  toggle(): void {
    if (this.isOpen) this.hide()
    else this.show()
  }

  show(): void {
    this.isOpen = true
    this.navigated = false
    this.docDirty = false
    // 진입 시점의 selection을 기억해 두고(item 4), 선택된 텍스트가 있으면 찾기 입력에
    // 시드한다(item 2). 둘 다 같은 selection 조회를 쓰므로 show에서 한 번에 처리.
    this.savedSelection = this.editor.getSelection()
    const selected = this.editor.getSelectionText()
    if (selected) this.findInput.value = selected
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
    if (this.replacedTimer) {
      clearTimeout(this.replacedTimer)
      this.replacedTimer = null
    }
    this.root.classList.add('hidden')
    this.editor.clearSearch()
    // 탐색 없이 닫았고(검색만 하다 Esc) 그동안 문서가 편집되지 않았다면 진입 시점
    // selection으로 되돌린다. 편집됐다면 저장 위치가 어긋나므로 복원하지 않는다(item 4).
    if (!this.navigated && !this.docDirty && this.savedSelection) {
      this.editor.restoreSelection(this.savedSelection)
    }
    this.savedSelection = null
    // 닫을 때 포커스가 허공에 남지 않도록 에디터로 되돌린다(item 1).
    this.editor.focus()
  }
}

function esc(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
}
function attr(s: string): string {
  return esc(s).replace(/"/g, '&quot;')
}
