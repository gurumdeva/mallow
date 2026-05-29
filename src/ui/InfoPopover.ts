import { Document } from '../domain/Document'
import { UIState } from '../domain/UIState'
import { EditorController } from '../editor/EditorController'
import { StatsCalculator, type Stats } from '../analysis/StatsCalculator'
import { TocExtractor } from '../analysis/TocExtractor'
import { t, getLocale } from '../i18n'

/**
 * 통계 / 목차 두 탭을 가진 popover.
 * UIState가 보유한 activeTab·infoPopoverOpen·collapsedTocGroups를 read해서 렌더.
 * 자체 인스턴스 상태 없음.
 */
export class InfoPopover {
  private readonly popover: HTMLDivElement
  private readonly btn: HTMLButtonElement

  constructor(
    private readonly doc: Document,
    private readonly uiState: UIState,
    private readonly editor: EditorController,
    private readonly stats: StatsCalculator,
    private readonly toc: TocExtractor,
  ) {
    this.popover = document.getElementById('stats-popover') as HTMLDivElement
    this.btn = document.getElementById('btn-info') as HTMLButtonElement
    this.bindDom()
    this.doc.on('changed', () => this.render())
    this.uiState.on('changed', () => this.render())
    this.render()
  }

  private bindDom(): void {
    this.btn.addEventListener('click', (e) => {
      e.stopPropagation()
      this.uiState.toggleInfoPopover()
    })
    this.popover.addEventListener('click', (e) => e.stopPropagation())
    document.addEventListener('click', (e) => {
      if (!this.uiState.infoPopoverOpen) return
      const t = e.target as Node
      if (this.popover.contains(t) || this.btn.contains(t)) return
      this.uiState.closeInfoPopover()
    })
    // Esc로 닫기 — Find/Filename/Style과 동작을 맞춘다(item 7). 열려 있을 때만 처리.
    document.addEventListener('keydown', (e) => {
      if (e.key === 'Escape' && this.uiState.infoPopoverOpen) {
        e.preventDefault()
        this.uiState.closeInfoPopover()
      }
    })
  }

  private render(): void {
    if (!this.uiState.infoPopoverOpen) {
      this.popover.classList.add('hidden')
      return
    }
    this.popover.classList.remove('hidden')

    const body =
      this.uiState.activeTab === 'stats' ? this.renderStatsBody() : this.renderTocBody()
    this.popover.innerHTML = this.renderHeader() + body

    this.bindRenderedHandlers()
  }

  private bindRenderedHandlers(): void {
    this.popover.querySelectorAll<HTMLButtonElement>('.stats-tab').forEach((tab) => {
      tab.addEventListener('click', (e) => {
        e.stopPropagation()
        const next = tab.dataset.tab as 'stats' | 'toc' | undefined
        if (next) this.uiState.setActiveTab(next)
      })
    })

    this.popover.querySelectorAll<HTMLButtonElement>('.toc-arrow').forEach((arrow) => {
      arrow.addEventListener('click', (e) => {
        e.stopPropagation()
        const groupEl = arrow.closest('.toc-group') as HTMLElement | null
        const groupIdx = parseInt(groupEl?.dataset.groupIdx ?? '0', 10)
        this.uiState.toggleTocGroup(groupIdx)
      })
    })

    // 목차 항목 클릭/키보드 활성화 → 해당 헤딩으로 점프. <button>이라 Enter/Space는 click으로
    // 들어온다(별도 keydown 불필요). 점프 대상은 "클릭 시점"에 .ProseMirror를 다시 조회해
    // 문서 순서대로 해석한다 — 렌더 때 캐시한 위치/요소가 그새 편집으로 어긋나도 올바르게 점프한다.
    this.popover.querySelectorAll<HTMLButtonElement>('.toc-item').forEach((item) => {
      item.addEventListener('click', (e) => {
        e.stopPropagation()
        const idx = parseInt(item.dataset.tocIdx ?? '0', 10)
        const items = this.toc.extract() // 클릭 시점 재추출(스테일 방지)
        const target = items[idx]?.element
        if (!target) return
        // 캐럿까지 함께 옮긴다(posAtDOM 실패 시 내부에서 DOM scrollIntoView로 폴백).
        this.editor.scrollToHeading(target)
        // 미니멀 UI: 점프 후 popover는 닫아 에디터에 집중하게 한다.
        this.uiState.closeInfoPopover()
      })
    })
  }

  // ─── Rendering helpers (순수 문자열 생성) ─────────────────
  private renderHeader(): string {
    const isStats = this.uiState.activeTab === 'stats'
    const title = isStats ? t('stats.title') : t('toc.title')
    return `
      <div class="stats-title">${title}</div>
      <div class="stats-tabs">
        <button class="stats-tab ${isStats ? 'active' : ''}" data-tab="stats" title="${t('stats.tabTip')}">
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M3 3v18h18"/><path d="M7 16V8M12 16v-5M17 16v-9"/></svg>
        </button>
        <button class="stats-tab ${!isStats ? 'active' : ''}" data-tab="toc" title="${t('toc.tabTip')}">
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><line x1="3" y1="6" x2="3.01" y2="6"/><line x1="3" y1="12" x2="3.01" y2="12"/><line x1="3" y1="18" x2="3.01" y2="18"/><line x1="8" y1="6" x2="21" y2="6"/><line x1="8" y1="12" x2="21" y2="12"/><line x1="8" y1="18" x2="21" y2="18"/></svg>
        </button>
      </div>
    `
  }

  private renderStatsBody(): string {
    const s: Stats = this.stats.calculate(this.editor.getMarkdown(), getLocale())
    const loc = getLocale()
    return `
      <div class="stats-grid">
        <div class="stat-card">
          <div class="stat-main">
            <div class="stat-value">${s.words.toLocaleString(loc)}</div>
            <div class="stat-label">${t('stats.words')}</div>
          </div>
          <svg class="stat-icon" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/></svg>
        </div>
        <div class="stat-card">
          <div class="stat-main">
            <div class="stat-value">${s.characters.toLocaleString(loc)}</div>
            <div class="stat-label">${t('stats.characters')}</div>
          </div>
          <span class="stat-icon" style="font-size:14px;font-weight:600;">Aa</span>
        </div>
        <div class="stat-card">
          <div class="stat-main">
            <div class="stat-value">${s.paragraphs.toLocaleString(loc)}</div>
            <div class="stat-label">${t('stats.paragraphs')}</div>
          </div>
          <span class="stat-icon" style="font-size:14px;">¶</span>
        </div>
        <div class="stat-card">
          <div class="stat-main">
            <div class="stat-value">${s.readMinutes}${t('stats.minuteUnit')}</div>
            <div class="stat-label">${t('stats.readTime')}</div>
          </div>
          <svg class="stat-icon" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/></svg>
        </div>
      </div>
      <div class="stats-meta">
        <div class="stats-meta-main">
          <div class="stats-meta-value">${this.formatDate(this.doc.lastModified)}</div>
          <div class="stats-meta-label">${t('stats.modDate')}</div>
        </div>
        <svg class="stat-icon" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="4" width="18" height="18" rx="2"/><line x1="16" y1="2" x2="16" y2="6"/><line x1="8" y1="2" x2="8" y2="6"/><line x1="3" y1="10" x2="21" y2="10"/></svg>
      </div>
    `
  }

  private renderTocBody(): string {
    const items = this.toc.extract()
    if (items.length === 0) {
      return `<div class="toc-empty">${t('toc.empty')}</div>`
    }
    const { groups, minLevel } = this.toc.group(items)
    // 각 항목은 "클릭 시 해당 헤딩으로 점프"하는 포커스 가능한 버튼이다(키보드 활성화 가능).
    // 접근성: 점프 버튼은 <button>(.toc-item), 그룹 펼침/접힘 화살표도 별도 <button>으로 분리해
    // 인터랙티브 요소를 중첩하지 않는다. 화살표는 aria-expanded로 상태를 노출한다.
    return `
      <div class="toc-list">
        ${groups
          .map((group, gi) => {
            const collapsed = this.uiState.isTocGroupCollapsed(gi)
            const hasChildren = group.children.length > 0
            return `
              <div class="toc-group ${collapsed ? 'collapsed' : ''}" data-group-idx="${gi}">
                <div class="toc-root-row">
                  ${
                    hasChildren
                      ? `<button type="button" class="toc-arrow" aria-expanded="${collapsed ? 'false' : 'true'}" aria-label="${t('toc.toggle')}"><svg width="10" height="10" viewBox="0 0 10 10" fill="currentColor"><path d="M2 3 L5 7 L8 3 Z"/></svg></button>`
                      : '<span class="toc-arrow-spacer"></span>'
                  }
                  <button type="button" class="toc-item toc-root toc-text" data-toc-idx="${group.rootIdx}" title="${t('toc.jump')}">${escapeHtml(group.root.text)}</button>
                </div>
                <div class="toc-children">
                  ${group.children
                    .map(
                      (c) => `
                    <button type="button" class="toc-item toc-child" data-toc-idx="${c.idx}" title="${t('toc.jump')}" style="padding-left: ${(c.item.level - minLevel) * 14 + 28}px">${escapeHtml(c.item.text)}</button>
                  `,
                    )
                    .join('')}
                </div>
              </div>
            `
          })
          .join('')}
      </div>
    `
  }

  private formatDate(d: Date): string {
    // Intl이 기기 언어에 맞는 날짜 표기를 자동 생성한다(영문 "May 29, 2026, 3:04 PM",
    // 한국어 "2026년 5월 29일 오후 3:04"). 직접 월 이름을 박지 않아 언어 혼용이 없다.
    return new Intl.DateTimeFormat(getLocale(), {
      year: 'numeric',
      month: 'long',
      day: 'numeric',
      hour: 'numeric',
      minute: '2-digit',
    }).format(d)
  }
}

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
}
