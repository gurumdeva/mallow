/**
 * 클립보드 텍스트가 "단일 http(s) URL"인지 판정한다 — 선택 텍스트가 있을 때 그 텍스트를
 * 붙여넣은 URL로 감싸(링크로 만들) 줄지 결정하는 데 쓴다.
 *
 * 규칙: 앞뒤 공백을 떼고, http:// 또는 https:// 로 시작하며 내부에 공백·개행이 없는 단일 토큰일 때만 true.
 *  - 공백/개행이 섞이면(여러 토큰·문장) false → 일반 붙여넣기로 둔다.
 *  - javascript:, data:, ftp:, mailto:, www.(스킴 없음) 등 비 http(s)는 false. http(s)만 허용해
 *    "선택 텍스트를 위험한 스킴 링크로 만드는" 경로를 원천 차단한다(붙여넣기 내보내기 sanitize와 일관).
 */
export function isBareUrl(text: string): boolean {
  return /^https?:\/\/\S+$/.test(text.trim())
}
