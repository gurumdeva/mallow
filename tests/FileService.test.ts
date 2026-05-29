import { describe, it, expect } from 'vitest'
import { shouldMarkSaved, decideSyncAction, SaveConflictError } from '../src/services/FileService.ts'

/**
 * FileService 의 "내용 기반 재조정" 순수 결정 함수에 대한 단위 테스트.
 *
 * save/sync 본문은 Tauri fs(writeTextFile/readTextFile/ask)에 의존해 단위 테스트가
 * 어렵다. 그래서 데이터 손실을 막는 핵심 판단을 순수 함수(shouldMarkSaved /
 * decideSyncAction)로 추출하고 여기서 그 규칙을 고정한다.
 *
 * 두 함수의 공통 원칙: dirty/reload 결정을 Milkdown markdownUpdated의 trailing 200ms
 * debounce 플래그(doc.isModified)가 아니라 "실제 내용"으로 내린다. 타이핑 도중에는
 * 그 플래그가 stale-false라, 비동기 write/reload가 진행 중 편집을 조용히 덮어쓸 수 있다.
 */

describe('shouldMarkSaved — write 직후 saved 처리 가부 (bug #2)', () => {
  it('write에 넣은 내용과 현재 에디터 내용이 같으면 true (정상 저장: write 도중 타이핑 없음)', () => {
    expect(shouldMarkSaved('# Hello', '# Hello')).toBe(true)
  })

  it('write await 동안 사용자가 더 타이핑해 내용이 달라지면 false (dirty 유지 → 후속 저장)', () => {
    // 디스크에는 '# Hello'를 썼지만 그 사이 에디터는 '# Hello world'가 됐다.
    // markSaved()를 하면 이 최신 편집의 dirty가 지워져 자동 저장이 다시 안 뜬다 → 손실.
    expect(shouldMarkSaved('# Hello', '# Hello world')).toBe(false)
  })

  it('빈 문서를 저장하면(둘 다 빈 문자열) true', () => {
    expect(shouldMarkSaved('', '')).toBe(true)
  })

  it('빈 내용을 쓰는 사이 타이핑이 들어오면 false', () => {
    expect(shouldMarkSaved('', 'typed during write')).toBe(false)
  })

  it('여러 줄이 완전히 동일하면 true', () => {
    const md = 'line1\nline2\n\n## section\n- a\n- b\n'
    expect(shouldMarkSaved(md, md)).toBe(true)
  })

  it('정확 비교다 — 끝 개행 같은 미세한 차이도 false로 본다(보수적)', () => {
    // 내용이 "그대로 같을 때만" saved 처리한다. 사소한 차이라도 다르면 dirty를 유지해
    // 후속 저장이 최신(개행 포함) 내용을 다시 쓰게 둔다.
    expect(shouldMarkSaved('text', 'text\n')).toBe(false)
    expect(shouldMarkSaved('a ', 'a')).toBe(false)
  })
})

describe('decideSyncAction — 외부 변경 동기화 결정 (bug #3)', () => {
  it("디스크가 마지막 IO 내용과 같으면 'noop' (외부 변경 없음)", () => {
    // editor 내용이 무엇이든(로컬 편집 있어도) 외부 변경 자체가 없으면 할 일이 없다.
    expect(decideSyncAction('anything', 'same', 'same')).toBe('noop')
    expect(decideSyncAction('local edit', 'same', 'same')).toBe('noop')
  })

  it("외부 변경 O + 로컬 편집 없음(editor == 마지막 IO) → 'silent' (안전하게 reload)", () => {
    // editor가 마지막으로 IO한 내용 그대로 = 로컬에서 손볼 게 없음 → 손실 위험 없이 덮어써도 된다.
    expect(decideSyncAction('disk-v1', 'disk-v1', 'disk-v2')).toBe('silent')
  })

  it("외부 변경 O + 로컬 편집 O(editor != 마지막 IO) → 'prompt' (충돌 확인)", () => {
    // 이것이 bug #3의 핵심: 로컬에서 진행 중인 편집(editor != lastDiskContent)이 있는데
    // 외부 변경까지 들어온 충돌 상황. debounce 플래그가 아니라 내용으로 판단하므로,
    // 타이핑 도중(플래그 stale-false)이라도 조용히 덮어쓰지 않고 사용자에게 묻는다.
    expect(decideSyncAction('local-in-progress', 'disk-v1', 'disk-v2')).toBe('prompt')
  })

  it('세 값이 모두 같으면 noop', () => {
    expect(decideSyncAction('x', 'x', 'x')).toBe('noop')
  })

  it("로컬 편집이 마침 외부 변경과 똑같아도, 마지막 IO와 다르면 'prompt' (보수적 확인)", () => {
    // editor == disk(우연히 같은 내용)지만 둘 다 마지막 IO와는 다르다 → 외부 변경 + 로컬 편집
    // 둘 다 존재로 보고 확인한다(내용 동일성까지 합쳐 자동 병합하지는 않음 — 단순/안전 우선).
    expect(decideSyncAction('merged', 'old', 'merged')).toBe('prompt')
  })

  it("빈 문자열 기준선에서도 규칙이 일관된다", () => {
    // 마지막 IO가 빈 내용(빈 파일을 저장/열기)인 경우.
    expect(decideSyncAction('', '', '')).toBe('noop')
    expect(decideSyncAction('', '', 'external')).toBe('silent') // 로컬 편집 없음
    expect(decideSyncAction('typed', '', 'external')).toBe('prompt') // 로컬 편집 있음
  })
})

describe('SaveConflictError — Save As가 다른 창에 열린 파일을 덮어쓰는 손실 방지 (cross-window)', () => {
  it('toast 표시용 fileName을 경로의 마지막 구성요소로 뽑는다', () => {
    const e = new SaveConflictError('/Users/me/notes/todo.md')
    expect(e.fileName).toBe('todo.md')
    expect(e.path).toBe('/Users/me/notes/todo.md')
  })

  it('instanceof로 식별 가능하고 name이 고정된다(호출부가 사유별 토스트를 고르는 기준)', () => {
    const e = new SaveConflictError('/x/y.md')
    expect(e).toBeInstanceOf(Error)
    expect(e).toBeInstanceOf(SaveConflictError)
    expect(e.name).toBe('SaveConflictError')
  })

  it('경로에 슬래시가 없으면 경로 전체를 fileName으로 쓴다(방어적)', () => {
    expect(new SaveConflictError('todo.md').fileName).toBe('todo.md')
  })
})
