export type TocItem = {
  text: string
  level: number
  element: HTMLElement
}

export type TocGroup = {
  root: TocItem
  rootIdx: number
  children: { item: TocItem; idx: number }[]
}

/**
 * 현재 화면 .ProseMirror에서 헤딩을 추출하고 2단계 트리로 묶는다.
 */
export class TocExtractor {
  extract(): TocItem[] {
    const headings = document.querySelectorAll<HTMLElement>(
      '.ProseMirror h1, .ProseMirror h2, .ProseMirror h3, .ProseMirror h4, .ProseMirror h5, .ProseMirror h6',
    )
    return Array.from(headings).map((el) => ({
      text: el.textContent?.trim() ?? '',
      level: parseInt(el.tagName.substring(1), 10),
      element: el,
    }))
  }

  group(items: TocItem[]): { groups: TocGroup[]; minLevel: number } {
    if (items.length === 0) return { groups: [], minLevel: 0 }
    const minLevel = Math.min(...items.map((i) => i.level))
    const groups: TocGroup[] = []
    let current: TocGroup | null = null
    items.forEach((item, idx) => {
      if (item.level === minLevel) {
        current = { root: item, rootIdx: idx, children: [] }
        groups.push(current)
      } else if (current) {
        current.children.push({ item, idx })
      } else {
        current = { root: item, rootIdx: idx, children: [] }
        groups.push(current)
      }
    })
    return { groups, minLevel }
  }
}
