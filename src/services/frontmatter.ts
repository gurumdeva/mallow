/**
 * YAML 프론트매터(문서 맨 앞 `---` … `---` 메타데이터 블록)를 본문과 분리/재결합하는 순수 함수.
 *
 * 왜 필요한가: Mallow의 에디터(Milkdown/Crepe)는 마크다운을 ProseMirror AST로 파싱한다.
 * 프론트매터의 여는 `---`는 thematic break(HR)로, 그 안의 `key: value`는 본문 텍스트로
 * 해석돼, 자동 저장이 AST를 다시 직렬화하면 프론트매터가 깨진다(조용한 데이터 손상 —
 * Obsidian/Hugo/Jekyll 노트 사용자에게 치명적). 해결책: 프론트매터를 "AST에 절대 넣지 않고"
 * 열 때 원문 그대로 떼어내 보관했다가, 디스크에 쓸 때만 다시 앞에 붙인다. 에디터는 본문만 본다.
 *
 * 인식 규칙(Obsidian/Jekyll 관례): 문서가 정확히 `---` 한 줄로 "시작"하고, 이후 어떤 줄이
 * 정확히 `---`(닫는 펜스)이면 그 사이(여는·닫는 펜스 포함)가 프론트매터다. 여는 펜스만 있고
 * 닫는 펜스가 없으면 프론트매터가 아니다(맨 앞 HR이거나 본문) — 문서 전체를 삼키지 않도록.
 * 두 펜스 모두 LF/CRLF 줄바꿈을 허용한다. 펜스는 정확히 `---`만 인정한다(앞뒤 공백 불가):
 * 흔치 않은 변형보다 오탐(본문을 메타로 오인)을 줄이는 쪽을 택한다. 설령 오탐이 나도
 * 분리된 블록은 원문 그대로 보존·재결합되므로 내용은 손실되지 않는다(에디터에 안 보일 뿐).
 */

/** 분리 결과. `frontmatter`는 여는 `---`부터 닫는 `---`까지(뒤 개행 제외)의 원문 그대로, 없으면 ''. */
export interface SplitContent {
  frontmatter: string
  body: string
}

// 여는 `---` 줄 + (0개 이상의 줄, 비탐욕) + 닫는 `---` 줄. `.`는 줄바꿈을 포함하지 않으므로
// `(?:.*\r?\n)*?`는 "줄 단위"로 비탐욕 매칭한다(catastrophic backtracking 없음). 캡처 그룹 1은
// 닫는 `---`까지(그 줄의 개행 제외); 그 뒤 `(?:\r?\n|$)`가 닫는 줄의 개행 또는 파일 끝을 소비한다.
const FRONTMATTER_RE = /^(---\r?\n(?:.*\r?\n)*?---)(?:\r?\n|$)/

/**
 * 선두 프론트매터를 떼어낸다. 없으면 `{ frontmatter: '', body: content }`.
 * 본문 앞쪽 개행(프론트매터와 본문 사이 빈 줄)은 제거해 에디터에 깨끗한 본문만 넘긴다
 * — 그 분리 간격은 [`composeFrontmatter`]가 표준 형태로 다시 만든다.
 */
export function splitFrontmatter(content: string): SplitContent {
  const m = FRONTMATTER_RE.exec(content)
  if (!m) return { frontmatter: '', body: content }
  const frontmatter = m[1]
  // m[0] = frontmatter + 닫는 줄의 개행. 그 뒤가 본문이며, 앞 개행은 제거한다.
  const body = content.slice(m[0].length).replace(/^\r?\n+/, '')
  return { frontmatter, body }
}

/**
 * 보관해 둔 프론트매터를 (에디터에서 나온) 본문 앞에 다시 붙여 디스크에 쓸 내용을 만든다.
 * 프론트매터가 없으면 본문 그대로. 있으면 프론트매터(닫는 `---`로 끝)와 본문 사이에 표준
 * 형태인 빈 줄 하나를 둔다(본문만 있을 땐 개행 하나로 닫는 줄을 종료).
 */
export function composeFrontmatter(frontmatter: string, body: string): string {
  if (frontmatter === '') return body
  if (body === '') return frontmatter + '\n'
  return frontmatter + '\n\n' + body
}
