import { describe, it, expect } from 'vitest'
import {
  isOpeningQuote,
  isOpeningSingleQuote,
  isApostrophe,
  isLetter,
  doubleQuoteFor,
  singleQuoteFor,
  dashFor,
  ellipsisFor,
  SMART_GLYPHS,
} from '../src/editor/smartTypography.ts'

// 스마트 타이포그래피의 "판단" 로직 단위 테스트. 에디터 없이 순수 함수만 검증한다.

describe('isOpeningQuote', () => {
  it('단락 맨 앞(앞 문자 없음)이면 여는 따옴표', () => {
    expect(isOpeningQuote(null)).toBe(true)
    expect(isOpeningQuote(undefined)).toBe(true)
    expect(isOpeningQuote('')).toBe(true)
  })

  it('공백류 뒤면 여는 따옴표', () => {
    expect(isOpeningQuote(' ')).toBe(true)
    expect(isOpeningQuote('\t')).toBe(true)
    expect(isOpeningQuote('\n')).toBe(true)
    expect(isOpeningQuote(' ')).toBe(true) // non-breaking space
  })

  it('여는 괄호류 뒤면 여는 따옴표', () => {
    expect(isOpeningQuote('(')).toBe(true)
    expect(isOpeningQuote('[')).toBe(true)
    expect(isOpeningQuote('{')).toBe(true)
    expect(isOpeningQuote('<')).toBe(true)
  })

  it('글자·숫자·닫는 괄호 뒤면 닫는 따옴표', () => {
    expect(isOpeningQuote('a')).toBe(false)
    expect(isOpeningQuote('Z')).toBe(false)
    expect(isOpeningQuote('5')).toBe(false)
    expect(isOpeningQuote(')')).toBe(false)
    expect(isOpeningQuote('.')).toBe(false)
  })
})

describe('doubleQuoteFor', () => {
  it('앞 문자에 따라 여는 “ / 닫는 ” 글리프를 고른다', () => {
    expect(doubleQuoteFor(null)).toBe(SMART_GLYPHS.openDouble) // “
    expect(doubleQuoteFor(' ')).toBe(SMART_GLYPHS.openDouble) // “
    expect(doubleQuoteFor('(')).toBe(SMART_GLYPHS.openDouble) // “
    expect(doubleQuoteFor('o')).toBe(SMART_GLYPHS.closeDouble) // ” (he said "hi" → 닫힘)
    expect(doubleQuoteFor('!')).toBe(SMART_GLYPHS.closeDouble) // ”
  })

  it('글리프가 실제 곡선 따옴표인지', () => {
    expect(SMART_GLYPHS.openDouble).toBe('“') // “
    expect(SMART_GLYPHS.closeDouble).toBe('”') // ”
  })
})

describe('isLetter', () => {
  it('라틴/한글/한자 글자는 true', () => {
    expect(isLetter('a')).toBe(true)
    expect(isLetter('Z')).toBe(true)
    expect(isLetter('가')).toBe(true)
    expect(isLetter('漢')).toBe(true)
  })

  it('숫자·기호·공백·null은 false', () => {
    expect(isLetter('5')).toBe(false)
    expect(isLetter('-')).toBe(false)
    expect(isLetter(' ')).toBe(false)
    expect(isLetter(null)).toBe(false)
    expect(isLetter(undefined)).toBe(false)
    expect(isLetter('')).toBe(false)
  })
})

describe('isApostrophe (글자 사이 작은따옴표)', () => {
  it('글자와 글자 사이면 아포스트로피 (don|t 의 t 직전)', () => {
    expect(isApostrophe('n', 't')).toBe(true) // don't
    expect(isApostrophe('t', 's')).toBe(true) // it's
  })

  it('한쪽이라도 글자가 아니면 아포스트로피가 아니다', () => {
    expect(isApostrophe('s', null)).toBe(false) // dogs' (뒤가 없음) → 아포스트로피 아님
    expect(isApostrophe(null, 't')).toBe(false) // 'twas (앞이 없음)
    expect(isApostrophe(' ', 't')).toBe(false)
    expect(isApostrophe('5', '0')).toBe(false) // 숫자 사이
  })
})

describe('singleQuoteFor', () => {
  it("글자 사이면 아포스트로피 ’ (don't → don’t)", () => {
    // n 과 t 사이의 ' → ’
    expect(singleQuoteFor('n', 't')).toBe(SMART_GLYPHS.closeSingle) // ’
  })

  it('단락 시작/공백/여는 괄호 뒤면 여는 ‘', () => {
    expect(singleQuoteFor(null, null)).toBe(SMART_GLYPHS.openSingle) // ‘
    expect(singleQuoteFor(' ', 'c')).toBe(SMART_GLYPHS.openSingle) // ' 'cause → ‘ ... 앞이 공백
    expect(singleQuoteFor('(', null)).toBe(SMART_GLYPHS.openSingle) // ‘
  })

  it('글자 뒤 + 다음 문자 없음(소유격 복수)이면 닫는 ’', () => {
    expect(singleQuoteFor('s', null)).toBe(SMART_GLYPHS.closeSingle) // dogs’ → ’
    expect(singleQuoteFor('!', null)).toBe(SMART_GLYPHS.closeSingle) // ’
  })

  it('isOpeningSingleQuote는 isOpeningQuote와 동일 규칙', () => {
    expect(isOpeningSingleQuote(' ')).toBe(true)
    expect(isOpeningSingleQuote('a')).toBe(false)
    expect(isOpeningSingleQuote(null)).toBe(true)
  })

  it('글리프가 실제 곡선 작은따옴표인지', () => {
    expect(SMART_GLYPHS.openSingle).toBe('‘') // ‘
    expect(SMART_GLYPHS.closeSingle).toBe('’') // ’
  })
})

describe('dashFor', () => {
  it('"--" → en dash –', () => {
    expect(dashFor('--')).toBe(SMART_GLYPHS.enDash)
    expect(SMART_GLYPHS.enDash).toBe('–') // –
  })

  it('"---" → em dash —', () => {
    expect(dashFor('---')).toBe(SMART_GLYPHS.emDash)
    expect(SMART_GLYPHS.emDash).toBe('—') // —
  })

  it('en dash 뒤 하이픈("–-")도 em dash — (타이핑 중 도달 경로)', () => {
    // 사용자가 -,-,- 를 순서대로 치면 "--"→"–" 먼저, 세 번째 -에서 "–-"가 되어 이 경로로 들어온다.
    expect(dashFor(SMART_GLYPHS.enDash + '-')).toBe(SMART_GLYPHS.emDash)
  })

  it('하이픈 1개나 알 수 없는 입력은 변환하지 않는다(null)', () => {
    expect(dashFor('-')).toBeNull()
    expect(dashFor('----')).toBeNull()
    expect(dashFor('')).toBeNull()
    expect(dashFor('a-')).toBeNull()
  })
})

describe('ellipsisFor', () => {
  it('"..." → 줄임표 …', () => {
    expect(ellipsisFor('...')).toBe(SMART_GLYPHS.ellipsis)
    expect(SMART_GLYPHS.ellipsis).toBe('…') // …
  })

  it('점 2개나 4개는 변환하지 않는다(null)', () => {
    expect(ellipsisFor('..')).toBeNull()
    expect(ellipsisFor('....')).toBeNull()
    expect(ellipsisFor('')).toBeNull()
  })
})
