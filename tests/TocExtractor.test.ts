import { describe, it, expect, afterEach } from 'vitest'
import { TocExtractor } from '../src/analysis/TocExtractor.ts'
import type { TocItem } from '../src/analysis/TocExtractor.ts'

const extractor = new TocExtractor()

/** `.ProseMirror` 컨테이너에 [tag, text] 헤딩들을 채워 document.body 에 붙인다. */
function mountProseMirror(headings: [tag: string, text: string][]): HTMLElement {
  const container = document.createElement('div')
  container.className = 'ProseMirror'
  for (const [tag, text] of headings) {
    const el = document.createElement(tag)
    el.textContent = text
    container.appendChild(el)
  }
  document.body.appendChild(container)
  return container
}

/** 테스트 헬퍼: 실제 DOM 없이 group() 만 검증할 때 쓰는 가짜 TocItem 생성기. */
function makeItem(level: number, text: string): TocItem {
  return { level, text, element: document.createElement(`h${level}`) }
}

afterEach(() => {
  document.body.innerHTML = ''
})

describe('TocExtractor.extract', () => {
  it('returns an empty array when there is no .ProseMirror', () => {
    expect(extractor.extract()).toEqual([])
  })

  it('extracts text, level, and element for h1..h6 in document order', () => {
    mountProseMirror([
      ['h1', 'Title'],
      ['h2', 'Section'],
      ['h3', 'Sub'],
      ['h4', 'Deep 4'],
      ['h5', 'Deep 5'],
      ['h6', 'Deep 6'],
    ])
    const items = extractor.extract()
    expect(items.map((i) => i.text)).toEqual([
      'Title',
      'Section',
      'Sub',
      'Deep 4',
      'Deep 5',
      'Deep 6',
    ])
    expect(items.map((i) => i.level)).toEqual([1, 2, 3, 4, 5, 6])
    // element 는 실제 DOM 노드를 가리킨다.
    expect(items[0]?.element.tagName).toBe('H1')
    expect(items[0]?.element.textContent).toBe('Title')
  })

  it('trims surrounding whitespace from heading text', () => {
    mountProseMirror([['h1', '  Padded  ']])
    expect(extractor.extract()[0]?.text).toBe('Padded')
  })

  it('ignores headings outside .ProseMirror', () => {
    const outside = document.createElement('h1')
    outside.textContent = 'Outside'
    document.body.appendChild(outside)
    mountProseMirror([['h2', 'Inside']])
    const items = extractor.extract()
    expect(items.map((i) => i.text)).toEqual(['Inside'])
  })
})

describe('TocExtractor.group', () => {
  it('returns empty groups and minLevel 0 for an empty list', () => {
    expect(extractor.group([])).toEqual({ groups: [], minLevel: 0 })
  })

  it('groups headings two levels deep by minLevel', () => {
    const items = [
      makeItem(1, 'A'),
      makeItem(2, 'A.1'),
      makeItem(2, 'A.2'),
      makeItem(1, 'B'),
      makeItem(2, 'B.1'),
    ]
    const { groups, minLevel } = extractor.group(items)
    expect(minLevel).toBe(1)
    expect(groups).toHaveLength(2)

    expect(groups[0]?.root.text).toBe('A')
    expect(groups[0]?.rootIdx).toBe(0)
    expect(groups[0]?.children.map((c) => c.item.text)).toEqual(['A.1', 'A.2'])
    expect(groups[0]?.children.map((c) => c.idx)).toEqual([1, 2])

    expect(groups[1]?.root.text).toBe('B')
    expect(groups[1]?.rootIdx).toBe(3)
    expect(groups[1]?.children.map((c) => c.item.text)).toEqual(['B.1'])
  })

  it('computes minLevel from the shallowest heading present (no h1)', () => {
    // h2 가 가장 얕으면 minLevel = 2, h3 들은 children 으로 묶인다.
    const items = [
      makeItem(2, 'Top'),
      makeItem(3, 'Mid'),
      makeItem(3, 'Mid2'),
    ]
    const { groups, minLevel } = extractor.group(items)
    expect(minLevel).toBe(2)
    expect(groups).toHaveLength(1)
    expect(groups[0]?.children.map((c) => c.item.text)).toEqual(['Mid', 'Mid2'])
  })

  it('handles a deeper heading appearing before any root (children-before-root)', () => {
    // 첫 항목이 minLevel 보다 깊으면 current 가 없어 자기 자신이 root 인 그룹이 된다.
    const items = [
      makeItem(2, 'Orphan'), // h1 보다 뒤에 나오는 h1 때문에 minLevel=1
      makeItem(1, 'Real Root'),
      makeItem(2, 'Child'),
    ]
    const { groups, minLevel } = extractor.group(items)
    expect(minLevel).toBe(1)
    expect(groups).toHaveLength(2)
    // 첫 그룹: minLevel 이 아닌 'Orphan' 이 root, children 없음.
    expect(groups[0]?.root.text).toBe('Orphan')
    expect(groups[0]?.rootIdx).toBe(0)
    expect(groups[0]?.children).toHaveLength(0)
    // 둘째 그룹: 'Real Root' + 'Child'
    expect(groups[1]?.root.text).toBe('Real Root')
    expect(groups[1]?.children.map((c) => c.item.text)).toEqual(['Child'])
  })

  it('groups a mix of levels, attaching all deeper headings to the nearest minLevel root', () => {
    const items = [
      makeItem(1, 'Intro'),
      makeItem(3, 'Deep under intro'), // h3 still attaches to h1 root
      makeItem(2, 'Body'),
      makeItem(1, 'Outro'),
    ]
    const { groups, minLevel } = extractor.group(items)
    expect(minLevel).toBe(1)
    expect(groups).toHaveLength(2)
    expect(groups[0]?.root.text).toBe('Intro')
    expect(groups[0]?.children.map((c) => c.item.text)).toEqual([
      'Deep under intro',
      'Body',
    ])
    expect(groups[1]?.root.text).toBe('Outro')
    expect(groups[1]?.children).toHaveLength(0)
  })

  it('integrates extract() output into group()', () => {
    mountProseMirror([
      ['h1', 'A'],
      ['h2', 'A.1'],
      ['h1', 'B'],
    ])
    const { groups, minLevel } = extractor.group(extractor.extract())
    expect(minLevel).toBe(1)
    expect(groups).toHaveLength(2)
    expect(groups[0]?.children.map((c) => c.item.text)).toEqual(['A.1'])
  })
})
