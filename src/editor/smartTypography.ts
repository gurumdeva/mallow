// ─── 스마트 타이포그래피(SmartyPants) 순수 결정 로직 ────────────────
// 사용자가 타이핑하는 ASCII 문장부호를 출판물 품질의 글리프로 바꾸는 "판단" 부분만 모았다.
//  - 직선 큰따옴표  "  → 여는 “ / 닫는 ”
//  - 직선 작은따옴표 '  → 여는 ‘ / 닫는·아포스트로피 ’   (don't → don’t)
//  - --  → en dash –,  ---  → em dash —
//  - ... → 줄임표 …
// ProseMirror/Crepe 의존이 전혀 없는 순수 함수만 둬서(에디터 없이 호출 가능) 단위 테스트가 쉽다.
// 실제 InputRule 결선은 smartTypographyRules.ts가 담당하며 여기 함수를 그대로 호출한다.
//
// ASCII 부호만 변환하므로 한국어·일본어 등 CJK 텍스트는 영향을 받지 않는다(전각 따옴표 등은 미변환).

/** 여는 따옴표로 볼 "앞 문자" 집합: 공백류 + 여는 괄호류 + 다른 따옴표. */
// 정규식 대신 명시적 집합으로 둬서 의도가 드러나고 테스트가 쉽다.
const OPENING_QUOTE_PREV = new Set<string>([
  ' ', '\t', '\n', '\r', '\f', '\v', ' ', // 공백류(스페이스/탭/개행/non-breaking space)
  '{', '[', '(', '<',                            // 여는 괄호류
  "'", '"', '‘', '“',                  // 다른 따옴표 바로 뒤도 여는 자리로 본다
])

/**
 * 직선 따옴표를 "여는" 방향으로 바꿔야 하는가? (큰따옴표·작은따옴표 공통 판단)
 *
 * 규칙: 텍스트 맨 앞이거나(prevChar가 없음) 앞 문자가 공백/여는 괄호/다른 따옴표면 여는 따옴표,
 * 그 외(글자·숫자·문장부호 뒤)는 닫는 따옴표.
 *
 * @param prevChar 따옴표 "직전" 문자. 단락 맨 앞이면 null 또는 빈 문자열.
 */
export function isOpeningQuote(prevChar: string | null | undefined): boolean {
  // 단락 시작(앞 문자 없음)이면 여는 따옴표.
  if (prevChar == null || prevChar === '') return true
  return OPENING_QUOTE_PREV.has(prevChar)
}

/**
 * 작은따옴표를 "아포스트로피(’)"로 처리해야 하는가?
 * 글자와 글자 사이(예: don't, it's, rock'n)에 오면 아포스트로피다. 닫는 작은따옴표와 글리프는
 * 같지만(둘 다 ’), 의미상 구분을 위해 별도 함수로 노출한다 — 테스트에서 의도를 명확히 하기 위함.
 *
 * @param prevChar 따옴표 직전 문자(없으면 null)
 * @param nextChar 따옴표 직후 문자(없으면 null) — 입력 시점엔 보통 아직 없음
 */
export function isApostrophe(
  prevChar: string | null | undefined,
  nextChar: string | null | undefined,
): boolean {
  return isLetter(prevChar) && isLetter(nextChar)
}

/** 유니코드 글자인지(라틴 외 한글·한자 등 포함). 숫자·기호·공백·null은 false. */
export function isLetter(ch: string | null | undefined): boolean {
  if (ch == null || ch === '') return false
  // \p{L} = 모든 언어의 "글자" 범주. u 플래그 필요.
  return /\p{L}/u.test(ch)
}

/** 직선 작은따옴표가 여는 따옴표(‘)인지 — isOpeningQuote와 동일 규칙이지만 의미 구분용 별칭. */
export function isOpeningSingleQuote(prevChar: string | null | undefined): boolean {
  return isOpeningQuote(prevChar)
}

// ─── 글리프 상수 ────────────────────────────────────────────────────
// 매직 문자열을 코드에 흩뿌리지 않도록 한곳에 모은다(테스트에서도 이 상수를 기대값으로 쓴다).
export const SMART_GLYPHS = {
  openDouble: '“', // “
  closeDouble: '”', // ”
  openSingle: '‘', // ‘
  closeSingle: '’', // ’  (닫는 작은따옴표 = 아포스트로피)
  enDash: '–', // –
  emDash: '—', // —
  ellipsis: '…', // …
} as const

/** 큰따옴표 글리프 선택: 앞 문자에 따라 여는 “ 또는 닫는 ”. */
export function doubleQuoteFor(prevChar: string | null | undefined): string {
  return isOpeningQuote(prevChar) ? SMART_GLYPHS.openDouble : SMART_GLYPHS.closeDouble
}

/**
 * 작은따옴표 글리프 선택: 글자 사이면 아포스트로피 ’, 아니면 앞 문자로 여는 ‘ / 닫는 ’ 판단.
 * (아포스트로피와 닫는 작은따옴표는 글리프가 같아 둘 다 ’ 가 된다 — 동작상 자연스럽다.)
 */
export function singleQuoteFor(
  prevChar: string | null | undefined,
  nextChar: string | null | undefined,
): string {
  if (isApostrophe(prevChar, nextChar)) return SMART_GLYPHS.closeSingle
  return isOpeningSingleQuote(prevChar) ? SMART_GLYPHS.openSingle : SMART_GLYPHS.closeSingle
}

/**
 * 연속 하이픈 → dash 매핑.
 *  - "--"  → en dash –
 *  - "---" → em dash —
 *
 * 주의: 입력 규칙은 매 키 입력마다 평가된다. 사용자가 -, -, - 를 순서대로 치면
 *  1) 두 번째 - 에서 "--" → "–"(en dash)로 먼저 바뀐다.
 *  2) 세 번째 - 입력 시 직전 텍스트는 "–-"(en dash + 하이픈) 가 된다.
 * 그래서 em dash를 "---" 리터럴로만 잡으면 절대 도달하지 못한다. 이 함수는 두 경우를 모두 받는다:
 *  - "--"  (앞 문자가 하이픈이 아닐 때)        → en dash
 *  - "---" 또는 "–-"(en dash 뒤 하이픈)        → em dash
 * 그 외(하이픈 1개 등)는 null 을 반환해 InputRule이 입력을 그대로 둔다.
 */
export function dashFor(hyphens: string): string | null {
  if (hyphens === '---' || hyphens === SMART_GLYPHS.enDash + '-') return SMART_GLYPHS.emDash
  if (hyphens === '--') return SMART_GLYPHS.enDash
  return null
}

/** "..." → 줄임표 …. 그 외 입력은 null. */
export function ellipsisFor(dots: string): string | null {
  return dots === '...' ? SMART_GLYPHS.ellipsis : null
}
