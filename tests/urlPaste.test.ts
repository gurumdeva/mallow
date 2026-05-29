import { describe, it, expect } from 'vitest'
import { isBareUrl } from '../src/editor/urlPaste.ts'

describe('isBareUrl — paste-URL-wraps-selection gate', () => {
  it('accepts a single http/https URL', () => {
    expect(isBareUrl('https://example.com')).toBe(true)
    expect(isBareUrl('http://example.com')).toBe(true)
    expect(isBareUrl('https://en.wikipedia.org/wiki/Foo_(bar)?q=1#frag')).toBe(true)
  })

  it('trims surrounding whitespace before judging', () => {
    expect(isBareUrl('  https://example.com\n')).toBe(true)
  })

  it('rejects multi-token / multi-line text (not a bare URL)', () => {
    expect(isBareUrl('https://example.com and more')).toBe(false)
    expect(isBareUrl('see https://example.com')).toBe(false)
    expect(isBareUrl('https://a.com\nhttps://b.com')).toBe(false)
    expect(isBareUrl('just some prose')).toBe(false)
    expect(isBareUrl('')).toBe(false)
  })

  it('rejects non-http(s) schemes (security: never wrap into a dangerous link)', () => {
    expect(isBareUrl('javascript:alert(1)')).toBe(false)
    expect(isBareUrl('data:text/html,<script>x</script>')).toBe(false)
    expect(isBareUrl('mailto:a@b.com')).toBe(false)
    expect(isBareUrl('ftp://host/file')).toBe(false)
    expect(isBareUrl('www.example.com')).toBe(false) // no scheme
  })
})
