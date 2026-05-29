/**
 * 창 부트스트랩 시 "이 창이 무엇을 열어야 하는가"를 결정하는 순수 함수.
 *
 * Tauri/IPC/DOM에 의존하지 않도록 입력을 평범한 값으로 받아, 부트스트랩의 미묘한
 * 우선순위 규칙을 단위 테스트로 고정할 수 있게 한다(main.ts는 이 결정을 실행만 한다).
 *
 * 우선순위(높은 → 낮은):
 *   1. 명시적 파일(explicit)   — URL 해시(#path) 또는 Finder cold-start로 넘어온 pending 경로.
 *                                사용자가 "직접 연" 파일이므로 무엇보다 우선한다.
 *   2. 마지막 문서 복원(restore-last) — 환영 문서를 이미 본 적 있고(welcomed) + 최근 파일이
 *                                존재할 때, 가장 최근 문서(recent[0])를 다시 연다("그냥 기억한다").
 *   3. 환영 문서(welcome)      — 최초 실행(welcomed=false)이고 열 파일이 없을 때 1회 표시.
 *   4. 빈 문서(blank)          — 그 외(복원할 최근 파일이 없는 재실행 등). 아무것도 열지 않는다.
 *
 * 주의: 복원/환영/빈 문서는 "main 최초 창"에서, 그리고 명시적 파일이 없을 때만 의미가 있다.
 * New/Open으로 생성된 doc-* 창은 항상 자신의 해시 경로(있으면)만 처리하거나 빈 문서로 둔다.
 */
export type StartupPlan =
  /** 명시적으로 지정된 파일을 연다(해시 또는 pending[0]). pending이 여러 개면 rest는 새 창으로. */
  | { kind: 'explicit'; path: string; openInNewWindows: string[] }
  /** 마지막으로 작업한 문서(recent[0])를 조용히 복원한다. 읽기 실패 시 빈 문서로 폴백(토스트 없음). */
  | { kind: 'restore-last'; path: string }
  /** 최초 실행 환영 문서를 표시한다. */
  | { kind: 'welcome' }
  /** 빈 새 문서(아무 동작 없음). */
  | { kind: 'blank' }

export type StartupInput = {
  /** 이 창의 label. 'main'이 아니면(doc-*) 복원/환영 로직은 적용되지 않는다. */
  windowLabel: string
  /** URL 해시에서 디코드한 파일 경로(없으면 null). New/Open/Finder warm-start 창이 사용. */
  hashFile: string | null
  /** Finder cold-start로 Rust가 stash해둔 경로들(webview_ready 반환값). main 창에서만 비어있지 않음. */
  pending: string[]
  /** localStorage 'mallow.welcomed' 플래그 존재 여부(이미 한 번이라도 환영 문서를 본 적 있는가). */
  welcomed: boolean
  /** 권위 있는 최근 파일 목록의 첫 항목(recent[0]). 없으면 null. 존재 여부는 호출부가 열어보며 확인. */
  recentTop: string | null
}

/**
 * 부트스트랩 입력으로부터 초기 동작을 결정한다(순수). 실제 파일 열기/환영 로드는
 * 호출부(main.ts)가 반환된 plan에 따라 수행한다.
 */
export function planStartup(input: StartupInput): StartupPlan {
  const { windowLabel, hashFile, pending, welcomed, recentTop } = input

  // (1) 해시에 경로가 있으면 그 파일을 연다 — New/Open/Finder warm-start 창의 정상 경로.
  //     명시적 열기이므로 어떤 복원/환영보다 우선한다.
  if (hashFile) {
    return { kind: 'explicit', path: hashFile, openInNewWindows: [] }
  }

  // 여기부터는 해시 없는 창. 복원/환영/빈 문서는 main 최초 창에서만 의미가 있다.
  // doc-* 창(해시 없이 생성된 New 창 등)은 빈 문서로 둔다.
  if (windowLabel !== 'main') {
    return { kind: 'blank' }
  }

  // (1') Finder cold-start: WebView mount 전 RunEvent::Opened가 stash한 경로들.
  //      첫 파일은 이 창에, 나머지는 새 창으로. 역시 명시적 열기라 최우선.
  if (pending.length > 0) {
    return { kind: 'explicit', path: pending[0], openInNewWindows: pending.slice(1) }
  }

  // (2) 마지막 문서 복원: 환영 문서를 본 적 있고(=실제 사용 이력 있음) 최근 파일이 있으면
  //     그 문서를 다시 연다. (최초 실행 환영 흐름을 절대 덮지 않도록 welcomed로 가드.)
  if (welcomed && recentTop) {
    return { kind: 'restore-last', path: recentTop }
  }

  // (3) 최초 실행 + 열 파일 없음 → 환영 문서 1회.
  if (!welcomed) {
    return { kind: 'welcome' }
  }

  // (4) 그 외(이미 환영 봤고 복원할 최근 파일도 없음) → 빈 문서.
  return { kind: 'blank' }
}
