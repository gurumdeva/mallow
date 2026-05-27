import { Document } from '../domain/Document'
import { UIState } from '../domain/UIState'
import { EditorController } from '../editor/EditorController'
import { StatsCalculator, type Stats } from '../analysis/StatsCalculator'
import { TocExtractor } from '../analysis/TocExtractor'

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

    this.popover.querySelectorAll<HTMLElement>('.toc-arrow').forEach((arrow) => {
      arrow.addEventListener('click', (e) => {
        e.stopPropagation()
        const groupEl = arrow.closest('.toc-group') as HTMLElement | null
        const groupIdx = parseInt(groupEl?.dataset.groupIdx ?? '0', 10)
        this.uiState.toggleTocGroup(groupIdx)
      })
    })

    this.popover.querySelectorAll<HTMLDivElement>('.toc-item').forEach((item) => {
      item.addEventListener('click', (e) => {
        if ((e.target as HTMLElement).closest('.toc-arrow')) return
        e.stopPropagation()
        const idx = parseInt(item.dataset.tocIdx ?? '0', 10)
        const items = this.toc.extract()
        items[idx]?.element.scrollIntoView({ behavior: 'smooth', block: 'start' })
      })
    })
  }

  // ─── Rendering helpers (순수 문자열 생성) ─────────────────
  private renderHeader(): string {
    const title = this.uiState.activeTab === 'stats' ? 'Statistics' : 'Table of Contents'
    const isStats = this.uiState.activeTab === 'stats'
    return `
      <div class="stats-title">${title}</div>
      <div class="stats-tabs">
        <button class="stats-tab ${isStats ? 'active' : ''}" data-tab="stats" title="통계">
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M3 3v18h18"/><path d="M7 16V8M12 16v-5M17 16v-9"/></svg>
        </button>
        <button class="stats-tab ${!isStats ? 'active' : ''}" data-tab="toc" title="목차">
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><line x1="3" y1="6" x2="3.01" y2="6"/><line x1="3" y1="12" x2="3.01" y2="12"/><line x1="3" y1="18" x2="3.01" y2="18"/><line x1="8" y1="6" x2="21" y2="6"/><line x1="8" y1="12" x2="21" y2="12"/><line x1="8" y1="18" x2="21" y2="18"/></svg>
        </button>
      </div>
    `
  }

  private renderStatsBody(): string {
    const s: Stats = this.stats.calculate(this.editor.getMarkdown())
    return `
      <div class="stats-grid">
        <div class="stat-card">
          <div class="stat-main">
            <div class="stat-value">${s.words.toLocaleString()}</div>
            <div class="stat-label">Words</div>
          </div>
          <svg class="stat-icon" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/></svg>
        </div>
        <div class="stat-card">
          <div class="stat-main">
            <div class="stat-value">${s.characters.toLocaleString()}</div>
            <div class="stat-label">Characters</div>
          </div>
          <span class="stat-icon" style="font-size:14px;font-weight:600;">Aa</span>
        </div>
        <div class="stat-card">
          <div class="stat-main">
            <div class="stat-value">${s.paragraphs}</div>
            <div class="stat-label">Paragraphs</div>
          </div>
          <span class="stat-icon" style="font-size:14px;">¶</span>
        </div>
        <div class="stat-card">
          <div class="stat-main">
            <div class="stat-value">${s.readMinutes}m</div>
            <div class="stat-label">Read Time</div>
          </div>
          <svg class="stat-icon" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/></svg>
        </div>
      </div>
      <div class="stats-meta">
        <div class="stats-meta-main">
          <div class="stats-meta-value">${this.formatDate(this.doc.lastModified)}</div>
          <div class="stats-meta-label">Modification Date</div>
        </div>
        <svg class="stat-icon" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="4" width="18" height="18" rx="2"/><line x1="16" y1="2" x2="16" y2="6"/><line x1="8" y1="2" x2="8" y2="6"/><line x1="3" y1="10" x2="21" y2="10"/></svg>
      </div>
    `
  }

  private renderTocBody(): string {
    const items = this.toc.extract()
    if (items.length === 0) {
      return '<div class="toc-empty">표시할 헤딩이 없습니다.</div>'
    }
    const { groups, minLevel } = this.toc.group(items)
    return `
      <div class="toc-list">
        ${groups
          .map((group, gi) => {
            const collapsed = this.uiState.isTocGroupCollapsed(gi)
            const hasChildren = group.children.length > 0
            return `
              <div class="toc-group ${collapsed ? 'collapsed' : ''}" data-group-idx="${gi}">
                <div class="toc-item toc-root" data-toc-idx="${group.rootIdx}">
                  ${
                    hasChildren
                      ? '<span class="toc-arrow"><svg width="10" height="10" viewBox="0 0 10 10" fill="currentColor"><path d="M2 3 L5 7 L8 3 Z"/></svg></span>'
                      : '<span class="toc-arrow-spacer"></span>'
                  }
                  <span class="toc-text">${escapeHtml(group.root.text)}</span>
                </div>
                <div class="toc-children">
                  ${group.children
                    .map(
                      (c) => `
                    <div class="toc-item toc-child" data-toc-idx="${c.idx}" style="padding-left: ${(c.item.level - minLevel) * 14 + 28}px">
                      ${escapeHtml(c.item.text)}
                    </div>
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
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December',
    ]
    const hour12 = d.getHours() % 12 || 12
    const ampm = d.getHours() >= 12 ? 'PM' : 'AM'
    const minute = String(d.getMinutes()).padStart(2, '0')
    return `${months[d.getMonth()]} ${d.getDate()}, ${d.getFullYear()} at ${hour12}:${minute}${ampm}`
  }
}

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
}
