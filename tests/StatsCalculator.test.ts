import { describe, it, expect } from 'vitest'
import { StatsCalculator } from '../src/analysis/StatsCalculator.ts'

const calc = new StatsCalculator()

describe('StatsCalculator.calculate', () => {
  it('returns all zeros for empty input', () => {
    expect(calc.calculate('')).toEqual({
      words: 0,
      characters: 0,
      paragraphs: 0,
      readMinutes: 0,
    })
  })

  it('returns all zeros for whitespace-only input (trimmed to empty)', () => {
    expect(calc.calculate('   \n\n  \t ')).toEqual({
      words: 0,
      characters: 0,
      paragraphs: 0,
      readMinutes: 0,
    })
  })

  it('counts English words split on whitespace', () => {
    const stats = calc.calculate('the quick brown fox')
    expect(stats.words).toBe(4)
  })

  it('collapses runs of whitespace when counting words', () => {
    // 다중 공백/탭/개행이 섞여도 빈 토큰은 제거된다.
    const stats = calc.calculate('one   two\t\tthree\nfour')
    expect(stats.words).toBe(4)
  })

  it('counts Korean 어절 by whitespace separation', () => {
    // "오늘 날씨 좋다" → 공백으로 분리된 3 어절.
    const stats = calc.calculate('오늘 날씨 좋다')
    expect(stats.words).toBe(3)
    // 문자 수는 공백 포함 trim 길이("오늘 날씨 좋다" = 8자)
    expect(stats.characters).toBe('오늘 날씨 좋다'.length)
  })

  it('counts characters as the trimmed length', () => {
    const stats = calc.calculate('  hello  ')
    expect(stats.characters).toBe('hello'.length)
  })

  it('splits paragraphs on two-or-more newlines', () => {
    const md = 'First paragraph.\n\nSecond paragraph.\n\n\nThird paragraph.'
    expect(calc.calculate(md).paragraphs).toBe(3)
  })

  it('treats a single newline as the same paragraph', () => {
    const md = 'line one\nline two'
    expect(calc.calculate(md).paragraphs).toBe(1)
  })

  it('ignores blank chunks between paragraph breaks', () => {
    // 사이가 공백만 있는 청크는 paragraph 로 세지 않는다.
    const md = 'A\n\n   \n\nB'
    expect(calc.calculate(md).paragraphs).toBe(2)
  })

  it('readMinutes is at least 1 for short non-empty text', () => {
    expect(calc.calculate('hi').readMinutes).toBe(1)
  })

  it('CJK read-time uses chars/500 at the 500 boundary (ko)', () => {
    const text = '가'.repeat(500)
    expect(calc.calculate(text, 'ko')).toMatchObject({
      characters: 500,
      readMinutes: 1, // ceil(500/500) = 1
    })
  })

  it('CJK read-time rounds up just past a 500-char boundary (ko)', () => {
    const text = '가'.repeat(501)
    expect(calc.calculate(text, 'ko').readMinutes).toBe(2) // ceil(501/500)
  })

  it('CJK read-time for a large document (ja)', () => {
    const text = 'あ'.repeat(1500)
    expect(calc.calculate(text, 'ja').readMinutes).toBe(3) // ceil(1500/500)
  })

  it('English read-time uses words/200, not chars/500', () => {
    // 250 words → ceil(250/200) = 2 min. Under the old chars/500 rule a 250-word
    // English doc (~1500 chars) would read as 3 min; word-based is more realistic.
    const text = Array.from({ length: 250 }, () => 'word').join(' ')
    expect(calc.calculate(text, 'en').readMinutes).toBe(2)
  })

  it('counts unspaced Japanese as multiple words (Intl.Segmenter), not one', () => {
    // 공백 split이라면 1단어로 셌을 문장을 사전 기반 분절로 여러 단어로 센다.
    const stats = calc.calculate('今日はいい天気', 'ja')
    expect(stats.words).toBeGreaterThan(1)
  })

  it('excludes headings, list items, and code blocks from paragraph count', () => {
    const md = [
      '# Title', // heading — not a paragraph
      '',
      'A real prose paragraph here.', // paragraph
      '',
      '- item one', // list — not a paragraph
      '- item two',
      '',
      '```', // code block — not a paragraph
      'const x = 1',
      '```',
      '',
      '> a quote', // blockquote — not a paragraph
      '',
      'Another prose paragraph.', // paragraph
    ].join('\n')
    expect(calc.calculate(md, 'en').paragraphs).toBe(2)
  })

  it('excludes image markdown (incl. a huge base64 data URI) from all stats', () => {
    // 붙여넣은 이미지의 거대한 data URI가 글자 수·읽기 시간을 부풀리면 안 된다.
    const huge = 'A'.repeat(100000)
    const md = `hello world ![shot](data:image/png;base64,${huge})`
    const s = calc.calculate(md)
    expect(s.words).toBe(2) // "hello", "world" — 이미지는 제외
    expect(s.characters).toBe('hello world'.length)
    expect(s.readMinutes).toBe(1) // 거대한 data URI가 빠져 1분
  })

  it('an image-only document counts as empty (no text)', () => {
    const md = '![](data:image/png;base64,iVBORw0KGgoAAAANSUhEUg==)'
    expect(calc.calculate(md)).toEqual({
      words: 0,
      characters: 0,
      paragraphs: 0,
      readMinutes: 0,
    })
  })

  it('does not count standalone image lines as prose paragraphs', () => {
    // 본문 1문단 + 이미지 3장 → 문단은 1로 세야 한다(이미지 줄은 문단 아님).
    const md = 'My notes\n\n![](a.png)\n\n![](b.png)\n\n![](c.png)'
    expect(calc.calculate(md, 'en').paragraphs).toBe(1)
    expect(calc.calculate('hello\n\n![a](x.png)', 'en').paragraphs).toBe(1)
  })

  it('strips image URLs containing one level of nested parentheses cleanly', () => {
    // URL에 괄호가 있어도(위키백과 Foo_(bar)) 잔여 ")" 없이 통째로 제거된다.
    const md = 'see ![map](https://en.wikipedia.org/wiki/Foo_(bar)) here'
    const s = calc.calculate(md, 'en')
    expect(s.characters).toBe('see  here'.length) // 이미지 자리만 사라지고 잔여 문자 없음
    expect(s.words).toBe(2) // "see", "here"
  })
})
