import { Document } from '../domain/Document'
import { EditorController } from '../editor/EditorController'
import { StatsCalculator } from '../analysis/StatsCalculator'
import { t, getLocale } from '../i18n'

/**
 * 우측 하단의 은은한 단어 수 / 읽기 시간 표시(글쓰기 피드백).
 * 빈 문서에서는 숨겨 미니멀한 첫 화면을 유지한다.
 * 자체 상태 없음 — doc 'changed'(편집)와 editor 'selectionchange'(선택 변화)를 구독해
 * editor 내용으로 다시 계산한다. 선택이 있으면 그 선택의 단어/글자 수를, 없으면 전체
 * 문서의 단어 수/읽기 시간을 보여 준다(MarkText #2791).
 */
export class StatusBar {
  private readonly el: HTMLDivElement

  constructor(
    private readonly doc: Document,
    private readonly editor: EditorController,
    private readonly stats: StatsCalculator,
  ) {
    const existing = document.getElementById('status-bar') as HTMLDivElement | null
    if (existing) {
      this.el = existing
    } else {
      this.el = document.createElement('div')
      this.el.id = 'status-bar'
      this.el.className = 'hidden'
      document.body.appendChild(this.el)
    }
    // 라이브 단어 수를 보조기술이 읽을 수 있게 live region으로 노출(item 12).
    // 시각적으로는 그대로 장식 요소(pointer-events:none, CSS)다.
    this.el.setAttribute('role', 'status')
    this.el.setAttribute('aria-live', 'polite')
    this.doc.on('changed', () => this.render())
    // 선택만 바뀌어도(편집 없이) 다시 계산하도록 editor의 selectionchange를 구독한다.
    this.editor.on('selectionchange', () => this.render())
    this.render()
  }

  private render(): void {
    const loc = getLocale()
    // 선택이 비어 있지 않으면 그 선택 텍스트의 통계를 우선 보여 준다.
    const selected = this.editor.getSelectionText()
    if (selected !== '') {
      // StatsCalculator가 이미지 제거·CJK 분절을 그대로 처리하므로 중복 계산 없이 재사용한다.
      const sel = this.stats.calculate(selected, loc)
      this.el.classList.remove('hidden')
      this.el.textContent = t('status.selection', {
        words: sel.words.toLocaleString(loc),
        chars: sel.characters.toLocaleString(loc),
      })
      return
    }

    const s = this.stats.calculate(this.editor.getMarkdown(), loc)
    if (s.characters === 0) {
      this.el.classList.add('hidden')
      return
    }
    this.el.classList.remove('hidden')
    this.el.textContent = t('status.summary', {
      words: s.words.toLocaleString(loc),
      min: s.readMinutes,
    })
  }
}
