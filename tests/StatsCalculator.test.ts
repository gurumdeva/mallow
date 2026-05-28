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

  it('readMinutes = ceil(characters / 500) at the 500 boundary', () => {
    const text = 'a'.repeat(500)
    expect(calc.calculate(text)).toMatchObject({
      characters: 500,
      readMinutes: 1, // ceil(500/500) = 1
    })
  })

  it('readMinutes rounds up just past a 500-char boundary', () => {
    const text = 'a'.repeat(501)
    expect(calc.calculate(text)).toMatchObject({
      characters: 501,
      readMinutes: 2, // ceil(501/500) = 2
    })
  })

  it('readMinutes for a large document', () => {
    const text = 'a'.repeat(1500)
    expect(calc.calculate(text).readMinutes).toBe(3) // ceil(1500/500)
  })
})
