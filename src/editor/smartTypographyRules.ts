// ─── 스마트 타이포그래피: ProseMirror 입력 규칙(InputRule) 결선 ──────
// smartTypography.ts의 순수 판단 함수를 실제 InputRule로 감싸 Milkdown에 등록한다.
//
// Milkdown 공식 경로($inputRule):
//  - $inputRule로 만든 규칙은 core의 단일 inputRules({rules}) 플러그인에 합쳐진다.
//  - 그 플러그인은 handleTextInput으로만 발화하고 view.composing(IME 조합) 중엔 건너뛰므로
//    한글/일본어 조합이 깨지지 않는다. ASCII 부호만 매칭하므로 CJK 본문도 영향 없다.
//  - core 기본 키맵이 Backspace를 chainCommands(undoInputRule, …)로 묶어, 치환 직후 Backspace나
//    ⌘Z(history)로 방금 친 원래 글자가 복원된다(undoable 기본 true).
//
// 코드 범위 제외(요구사항 핵심):
//  - InputRule은 기본적으로 code_block(NodeSpec.code) 안에서 발화하지 않는다(inCode 기본 false).
//  - inline code 마크(MarkSpec.code) 안에서도 막으려면 inCodeMark:false 가 필요하다.
//    inputRules의 run()이 매치 구간에 code 마크가 있으면 규칙을 건너뛴다.
//  → 따라서 모든 규칙에 { inCodeMark: false } 를 주고 inCode는 기본값(false)으로 둔다.
//    결과적으로 따옴표/대시/줄임표는 코드블록·인라인코드 안에서 변환되지 않는다.

import { InputRule } from '@milkdown/prose/inputrules'
import { $inputRule } from '@milkdown/utils'
import {
  doubleQuoteFor,
  singleQuoteFor,
  dashFor,
  ellipsisFor,
  SMART_GLYPHS,
} from './smartTypography'

// 코드(블록/마크) 안에서는 변환하지 않도록 모든 규칙에 공통 적용하는 옵션.
const NOT_IN_CODE = { inCodeMark: false } as const

/**
 * 매치 시작 위치 "직전"의 단락 내 문자 1개를 돌려준다(없으면 null).
 * 따옴표 여닫음 판단에 쓰인다. ￼(leaf placeholder)는 글자가 아니므로 null로 본다.
 */
function prevCharAt(state: import('@milkdown/prose/state').EditorState, start: number): string | null {
  const $start = state.doc.resolve(start)
  // 같은 단락(textblock) 안에서의 오프셋. 0이면 단락 맨 앞 → 앞 문자 없음.
  const offset = $start.parentOffset
  if (offset <= 0) return null
  const before = $start.parent.textBetween(offset - 1, offset, undefined, '￼')
  if (!before || before === '￼') return null
  return before
}

/** 큰따옴표 " → 여는 “ / 닫는 ”. 앞 문자로 방향을 정한다. */
const doubleQuoteRule = $inputRule(
  () =>
    new InputRule(
      /"$/,
      (state, _match, start, end) => {
        const glyph = doubleQuoteFor(prevCharAt(state, start))
        return state.tr.insertText(glyph, start, end)
      },
      NOT_IN_CODE,
    ),
)

/** 작은따옴표 ' → 여는 ‘ / 닫는·아포스트로피 ’. 글자 사이면 아포스트로피(don't → don’t). */
const singleQuoteRule = $inputRule(
  () =>
    new InputRule(
      /'$/,
      (state, _match, start, end) => {
        const prev = prevCharAt(state, start)
        // nextChar: ' 직후 문자. 타이핑 시점엔 보통 캐럿이 끝이라 없음(null) → 여는/닫는만 판단.
        const $end = state.doc.resolve(end)
        const nextOffset = $end.parentOffset
        const next =
          nextOffset < $end.parent.content.size
            ? $end.parent.textBetween(nextOffset, nextOffset + 1, undefined, '￼')
            : null
        const glyph = singleQuoteFor(prev, next === '￼' ? null : next)
        return state.tr.insertText(glyph, start, end)
      },
      NOT_IN_CODE,
    ),
)

// dash 규칙은 캡처 그룹 없는 단순 패턴을 쓴다. inputRules의 run()이 넘겨주는 start는 이미
// "문서에 들어있는 매치 구간의 시작"(방금 친 글자 분량을 제외한 위치)을 가리키므로, 핸들러는
// [start, end)를 글리프로 바꾸기만 하면 된다(ProseMirror 기본 string 핸들러와 동일 의미).
//
// 연속 -,-,- 입력 시 도달 경로:
//  1) 두 번째 - 에서 "--"가 매치 → enDashRule이 "–"로 치환.
//  2) 세 번째 - 에서 직전이 "–"라 "--"는 더 이상 매치되지 않고 "–-"가 매치 → emDashRule이 "—"로 치환.
// 두 패턴은 겹치지 않아("--" vs "–-") 서로 오발화하지 않는다.
//
// 블록 맨 앞 제외(중요): commonmark는 빈 줄 맨 앞의 "---"를 수평선(HR)으로 바꾸는 입력 규칙을 갖는다.
// dash 규칙을 무조건 켜면 두 번째 - 에서 "--"→"–"가 먼저 일어나 그 HR 단축을 가로채 버린다.
// 그래서 매치 구간 "앞 문자"가 없으면(=블록 맨 앞) dash 변환을 사양(null)해 commonmark HR이 살아있게 한다.
// 결과: 줄 맨 앞 "---"는 HR, 본문 중간 "--"/"---"는 en/em dash.
const blockStart = (state: import('@milkdown/prose/state').EditorState, start: number): boolean =>
  prevCharAt(state, start) === null

/** en dash: "--" → – (단, 블록 맨 앞이면 HR 단축을 위해 사양). */
const enDashRule = $inputRule(
  () =>
    new InputRule(
      /--$/,
      (state, _match, start, end) => {
        if (blockStart(state, start)) return null
        const glyph = dashFor('--')
        if (!glyph) return null
        return state.tr.insertText(glyph, start, end)
      },
      NOT_IN_CODE,
    ),
)

/** em dash: en dash(–) 뒤 하이픈("–-") → —. (리터럴 "---"는 enDash 단계를 거쳐 이 경로로 들어온다.) */
const emDashRule = $inputRule(
  () =>
    new InputRule(
      new RegExp(`${SMART_GLYPHS.enDash}-$`),
      (state, _match, start, end) => {
        // 여기 도달했다는 건 앞에 en dash(–)가 이미 있다는 뜻이라 블록 맨 앞일 수 없다(앞 문자 = –).
        const glyph = dashFor(SMART_GLYPHS.enDash + '-')
        if (!glyph) return null
        return state.tr.insertText(glyph, start, end)
      },
      NOT_IN_CODE,
    ),
)

/** "..." → 줄임표 …. */
const ellipsisRule = $inputRule(
  () =>
    new InputRule(
      /\.\.\.$/,
      (state, _match, start, end) => {
        const glyph = ellipsisFor('...')
        if (!glyph) return null
        return state.tr.insertText(glyph, start, end)
      },
      NOT_IN_CODE,
    ),
)

/**
 * 스마트 타이포그래피 입력 규칙 묶음. createCrepe에서 crepe.editor.use(...)로 펼쳐 등록한다.
 * em dash 규칙을 en dash보다 앞에 둬 "–-" 케이스가 먼저 평가되게 한다(둘은 매칭 영역이 겹치지 않지만
 * 의도를 분명히 하기 위함).
 */
export const smartTypographyRules = [
  emDashRule,
  enDashRule,
  ellipsisRule,
  doubleQuoteRule,
  singleQuoteRule,
]
