import { describe, it, expect } from 'vitest'
import { splitFrontmatter, composeFrontmatter } from '../src/services/frontmatter.ts'

/**
 * 프론트매터 분리/재결합 순수 함수 단위 테스트.
 *
 * 데이터 안전 핵심: 선두 YAML 프론트매터를 에디터(Milkdown AST)에 절대 넣지 않고 원문 그대로
 * 떼어내 보관했다가 저장 시 다시 붙인다 → 자동 저장이 프론트매터를 깨는 손상을 차단한다.
 * 가장 중요한 불변식: "떼어낸 프론트매터 블록의 바이트가 완전히 보존된다".
 */
describe('splitFrontmatter', () => {
  it('returns empty frontmatter + original body for plain text', () => {
    const r = splitFrontmatter('just some text\n\nmore')
    expect(r.frontmatter).toBe('')
    expect(r.body).toBe('just some text\n\nmore')
  })

  it('splits a basic frontmatter block from the body', () => {
    const r = splitFrontmatter('---\ntitle: Hello\n---\n\nbody text')
    expect(r.frontmatter).toBe('---\ntitle: Hello\n---')
    expect(r.body).toBe('body text')
  })

  it('handles multi-line frontmatter', () => {
    const content = '---\ntitle: Hello\ntags:\n  - a\n  - b\ndate: 2026-05-30\n---\n\n# Heading'
    const r = splitFrontmatter(content)
    expect(r.frontmatter).toBe('---\ntitle: Hello\ntags:\n  - a\n  - b\ndate: 2026-05-30\n---')
    expect(r.body).toBe('# Heading')
  })

  it('handles empty frontmatter', () => {
    const r = splitFrontmatter('---\n---\n\nbody')
    expect(r.frontmatter).toBe('---\n---')
    expect(r.body).toBe('body')
  })

  it('handles frontmatter with no body (trailing newline)', () => {
    const r = splitFrontmatter('---\ntitle: x\n---\n')
    expect(r.frontmatter).toBe('---\ntitle: x\n---')
    expect(r.body).toBe('')
  })

  it('handles frontmatter with no body and no trailing newline', () => {
    const r = splitFrontmatter('---\ntitle: x\n---')
    expect(r.frontmatter).toBe('---\ntitle: x\n---')
    expect(r.body).toBe('')
  })

  it('preserves CRLF line endings in the frontmatter byte-for-byte', () => {
    const r = splitFrontmatter('---\r\ntitle: x\r\n---\r\n\r\nbody')
    expect(r.frontmatter).toBe('---\r\ntitle: x\r\n---')
    expect(r.body).toBe('body')
  })

  it('does NOT treat a leading thematic break (no closing fence) as frontmatter', () => {
    const r = splitFrontmatter('---\n\nsome text after a horizontal rule')
    expect(r.frontmatter).toBe('')
    expect(r.body).toBe('---\n\nsome text after a horizontal rule')
  })

  it('does NOT treat a lone --- as frontmatter', () => {
    const r = splitFrontmatter('---')
    expect(r.frontmatter).toBe('')
    expect(r.body).toBe('---')
  })

  it('does NOT match ---- (four dashes) as an opening fence', () => {
    const r = splitFrontmatter('----\ntitle: x\n----\n\nbody')
    expect(r.frontmatter).toBe('')
    expect(r.body).toBe('----\ntitle: x\n----\n\nbody')
  })

  it('does NOT treat an opening fence with trailing spaces as frontmatter (strict)', () => {
    const r = splitFrontmatter('--- \ntitle: x\n---\n\nbody')
    expect(r.frontmatter).toBe('')
    expect(r.body).toBe('--- \ntitle: x\n---\n\nbody')
  })

  it('requires the frontmatter to start at the very beginning of the document', () => {
    const r = splitFrontmatter('intro\n---\ntitle: x\n---\n\nbody')
    expect(r.frontmatter).toBe('')
    expect(r.body).toBe('intro\n---\ntitle: x\n---\n\nbody')
  })

  it('only splits the FIRST block — a thematic break later in the body stays in the body', () => {
    const r = splitFrontmatter('---\ntitle: x\n---\n\npara one\n\n---\n\npara two')
    expect(r.frontmatter).toBe('---\ntitle: x\n---')
    expect(r.body).toBe('para one\n\n---\n\npara two')
  })

  it('strips multiple blank lines between frontmatter and body', () => {
    const r = splitFrontmatter('---\nt: x\n---\n\n\n\nbody')
    expect(r.frontmatter).toBe('---\nt: x\n---')
    expect(r.body).toBe('body')
  })
})

describe('composeFrontmatter', () => {
  it('returns the body unchanged when there is no frontmatter', () => {
    expect(composeFrontmatter('', 'body text')).toBe('body text')
  })

  it('joins frontmatter and body with a single blank line', () => {
    expect(composeFrontmatter('---\ntitle: x\n---', 'body')).toBe('---\ntitle: x\n---\n\nbody')
  })

  it('ends frontmatter with a newline when the body is empty', () => {
    expect(composeFrontmatter('---\ntitle: x\n---', '')).toBe('---\ntitle: x\n---\n')
  })
})

describe('round-trip', () => {
  it('reproduces a canonical frontmatter document exactly (split → compose)', () => {
    const original = '---\ntitle: Hello\ntags: [a, b]\n---\n\n# Body\n\nText.'
    const { frontmatter, body } = splitFrontmatter(original)
    expect(composeFrontmatter(frontmatter, body)).toBe(original)
  })

  it('canonicalizes a missing blank-line separator to one blank line', () => {
    // No blank line between fence and body → compose normalizes to the standard form.
    const { frontmatter, body } = splitFrontmatter('---\nt: x\n---\nbody')
    expect(composeFrontmatter(frontmatter, body)).toBe('---\nt: x\n---\n\nbody')
  })

  it('preserves the exact frontmatter bytes through a round-trip (CRLF)', () => {
    const original = '---\r\ntitle: x\r\ndate: 2026\r\n---\r\n\r\nbody'
    const { frontmatter } = splitFrontmatter(original)
    // The frontmatter block (the data-safety-critical part) is byte-identical.
    expect(frontmatter).toBe('---\r\ntitle: x\r\ndate: 2026\r\n---')
    // Recomposing puts the verbatim frontmatter back at the front.
    expect(composeFrontmatter(frontmatter, 'body').startsWith(frontmatter)).toBe(true)
  })

  it('a plain document with no frontmatter is unaffected by split → compose', () => {
    const original = '# Just markdown\n\nNo metadata here.'
    const { frontmatter, body } = splitFrontmatter(original)
    expect(frontmatter).toBe('')
    expect(composeFrontmatter(frontmatter, body)).toBe(original)
  })
})
