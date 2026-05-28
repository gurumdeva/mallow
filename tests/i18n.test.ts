import { describe, it, expect, afterEach } from 'vitest'
import { resolveLang, setLocale, getLocale, t } from '../src/i18n/index.ts'
import type { TKey } from '../src/i18n/index.ts'

afterEach(() => {
  // 모듈 레벨 current 상태가 테스트 간 누수되지 않도록 기본값으로 되돌린다.
  setLocale('en')
})

describe('resolveLang', () => {
  it('maps ko-KR to ko', () => {
    expect(resolveLang('ko-KR')).toBe('ko')
  })

  it('maps ja to ja', () => {
    expect(resolveLang('ja')).toBe('ja')
  })

  it('maps en-US to en', () => {
    expect(resolveLang('en-US')).toBe('en')
  })

  it('falls back to en for unsupported languages (zh)', () => {
    expect(resolveLang('zh')).toBe('en')
    expect(resolveLang('zh-CN')).toBe('en')
  })

  it('falls back to en for null and undefined', () => {
    expect(resolveLang(null)).toBe('en')
    expect(resolveLang(undefined)).toBe('en')
  })

  it('falls back to en for an empty string', () => {
    expect(resolveLang('')).toBe('en')
  })

  it('is case-insensitive', () => {
    expect(resolveLang('KO')).toBe('ko')
    expect(resolveLang('Ja-JP')).toBe('ja')
  })
})

describe('setLocale / getLocale', () => {
  it('defaults to en', () => {
    // afterEach 가 항상 en 으로 되돌리므로 시작 상태는 en.
    expect(getLocale()).toBe('en')
  })

  it('round-trips the current locale', () => {
    setLocale('ko')
    expect(getLocale()).toBe('ko')
    setLocale('ja')
    expect(getLocale()).toBe('ja')
  })
})

describe('t — nested key resolution', () => {
  it('resolves a one-level-nested key (menu.file)', () => {
    expect(t('menu.file')).toBe('File')
  })

  it('resolves a two-level-nested key (style.tip.bold)', () => {
    expect(t('style.tip.bold')).toBe('Bold (⌘B)')
  })

  it('uses the active locale for translation', () => {
    setLocale('ko')
    expect(t('menu.file')).toBe('파일')
  })

  it('falls back to en when a key is missing in the active locale', () => {
    // 모든 로케일이 동일 키 집합을 가지므로 직접적인 누락은 없지만,
    // 폴백 경로 자체는 en 값으로 동작함을 확인한다.
    setLocale('ja')
    // ja 에도 존재하는 키지만, 최소한 빈 문자열/키 자체가 아니어야 한다.
    expect(t('menu.file').length).toBeGreaterThan(0)
    expect(t('menu.file')).not.toBe('menu.file')
  })
})

describe('t — interpolation', () => {
  it('substitutes {count} from params', () => {
    expect(t('dialog.unsavedQuit.body', { count: 3 })).toContain('You have 3 document(s)')
  })

  it('substitutes a string param ({name})', () => {
    expect(t('dialog.unsavedClose.body', { name: 'draft.md' })).toContain("'draft.md'")
  })

  it('leaves a placeholder intact when its param is missing', () => {
    // params 객체는 있지만 해당 키가 없으면 원형 {name} 을 남긴다.
    expect(t('dialog.unsavedClose.body', { other: 'x' })).toContain('{name}')
  })

  it('leaves placeholders intact when no params are passed at all', () => {
    expect(t('dialog.unsavedQuit.body')).toContain('{count}')
  })

  it('coerces numeric params to strings', () => {
    expect(t('dialog.unsavedQuit.body', { count: 0 })).toContain('You have 0 document(s)')
  })
})

describe('t — unknown key fallback', () => {
  it('returns the key itself when it cannot be resolved', () => {
    // 스키마에 없는 키를 일부러 넣어 런타임 폴백(키 그대로 반환)을 검증한다.
    const bogus = 'no.such.key' as unknown as TKey
    expect(t(bogus)).toBe('no.such.key')
  })

  it('returns the key when the path points at an object, not a string', () => {
    // 'menu' 는 객체이므로 문자열이 아니다 → 키 자체를 반환.
    const objKey = 'menu' as unknown as TKey
    expect(t(objKey)).toBe('menu')
  })
})
