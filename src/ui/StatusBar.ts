import { Document } from '../domain/Document'
import { EditorController } from '../editor/EditorController'
import { StatsCalculator } from '../analysis/StatsCalculator'
import { t, getLocale } from '../i18n'

/**
 * 우측 하단의 은은한 단어 수 / 읽기 시간 표시(글쓰기 피드백).
 * 빈 문서에서는 숨겨 미니멀한 첫 화면을 유지한다.
 * 자체 상태 없음 — doc 'changed'를 구독해 editor 내용으로 다시 계산한다.
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
    this.render()
  }

  private render(): void {
    const s = this.stats.calculate(this.editor.getMarkdown(), getLocale())
    if (s.characters === 0) {
      this.el.classList.add('hidden')
      return
    }
    this.el.classList.remove('hidden')
    this.el.textContent = t('status.summary', {
      words: s.words.toLocaleString(getLocale()),
      min: s.readMinutes,
    })
  }
}
