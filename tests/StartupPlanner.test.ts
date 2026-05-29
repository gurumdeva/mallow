import { describe, it, expect } from 'vitest'
import { planStartup, type StartupInput } from '../src/services/StartupPlanner.ts'

/**
 * 부트스트랩 초기 동작 결정의 우선순위 규칙을 고정하는 단위 테스트.
 * 우선순위: 명시적 파일(해시/pending) > 마지막 문서 복원 > 최초 실행 환영 > 빈 문서.
 */

// 기본 입력: main 창, 해시 없음, pending 없음, 환영 본 적 있음, 최근 파일 없음.
const base: StartupInput = {
  windowLabel: 'main',
  hashFile: null,
  pending: [],
  welcomed: true,
  recentTop: null,
}

describe('planStartup — explicit file (highest priority)', () => {
  it('opens the hash file when present (doc-* window)', () => {
    const plan = planStartup({ ...base, windowLabel: 'doc-1', hashFile: '/a/b.md' })
    expect(plan).toEqual({ kind: 'explicit', path: '/a/b.md', openInNewWindows: [] })
  })

  it('hash file wins over restore-last on the main window', () => {
    // (실제로 main 창은 해시를 받지 않지만, 우선순위가 해시 우선임을 명시적으로 고정한다.)
    const plan = planStartup({
      ...base,
      hashFile: '/explicit.md',
      welcomed: true,
      recentTop: '/recent.md',
    })
    expect(plan).toEqual({ kind: 'explicit', path: '/explicit.md', openInNewWindows: [] })
  })

  it('opens pending[0] in this window and the rest in new windows (Finder cold-start)', () => {
    const plan = planStartup({ ...base, pending: ['/one.md', '/two.md', '/three.md'] })
    expect(plan).toEqual({
      kind: 'explicit',
      path: '/one.md',
      openInNewWindows: ['/two.md', '/three.md'],
    })
  })

  it('pending wins over restore-last even when a recent file exists', () => {
    const plan = planStartup({
      ...base,
      pending: ['/opened.md'],
      welcomed: true,
      recentTop: '/recent.md',
    })
    expect(plan).toEqual({ kind: 'explicit', path: '/opened.md', openInNewWindows: [] })
  })

  it('pending wins over welcome on a first-ever run opened via Finder', () => {
    const plan = planStartup({ ...base, pending: ['/opened.md'], welcomed: false })
    expect(plan).toEqual({ kind: 'explicit', path: '/opened.md', openInNewWindows: [] })
  })
})

describe('planStartup — restore last document', () => {
  it('restores recent[0] when welcomed and a recent file exists', () => {
    const plan = planStartup({ ...base, welcomed: true, recentTop: '/Users/me/last.md' })
    expect(plan).toEqual({ kind: 'restore-last', path: '/Users/me/last.md' })
  })

  it('does NOT restore when not yet welcomed (welcome takes precedence)', () => {
    // 최초 실행 환영 흐름을 절대 덮지 않는다: welcomed=false면 복원하지 않고 welcome으로 간다.
    const plan = planStartup({ ...base, welcomed: false, recentTop: '/Users/me/last.md' })
    expect(plan).toEqual({ kind: 'welcome' })
  })

  it('does NOT restore when there is no recent file (falls through to blank)', () => {
    const plan = planStartup({ ...base, welcomed: true, recentTop: null })
    expect(plan).toEqual({ kind: 'blank' })
  })
})

describe('planStartup — first-run welcome', () => {
  it('shows welcome on a first-ever run with no file and no recents', () => {
    const plan = planStartup({ ...base, welcomed: false, recentTop: null })
    expect(plan).toEqual({ kind: 'welcome' })
  })
})

describe('planStartup — blank fallback', () => {
  it('returns blank for a welcomed re-launch with no file and no recents', () => {
    const plan = planStartup({ ...base, welcomed: true, recentTop: null })
    expect(plan).toEqual({ kind: 'blank' })
  })
})

describe('planStartup — non-main (doc-*) windows', () => {
  it('opens the hash file for a doc-* window', () => {
    const plan = planStartup({ ...base, windowLabel: 'doc-xyz', hashFile: '/d.md' })
    expect(plan).toEqual({ kind: 'explicit', path: '/d.md', openInNewWindows: [] })
  })

  it('is blank for a doc-* window with no hash (never restores/welcomes)', () => {
    // doc-* 창은 복원/환영 대상이 아니다. 최근 파일이 있어도, 환영을 본 적 없어도 빈 문서.
    const plan = planStartup({
      ...base,
      windowLabel: 'doc-xyz',
      hashFile: null,
      welcomed: false,
      recentTop: '/recent.md',
    })
    expect(plan).toEqual({ kind: 'blank' })
  })

  it('ignores pending for a doc-* window (pending is a main-only concept)', () => {
    // 안전장치: 어떤 이유로 doc-* 창에 pending이 들어와도 복원/명시 경로로 가지 않는다
    // (main 창만 webview_ready로 pending을 가져오므로 실제로는 비어 있다).
    const plan = planStartup({ ...base, windowLabel: 'doc-1', pending: ['/x.md'] })
    expect(plan).toEqual({ kind: 'blank' })
  })
})
