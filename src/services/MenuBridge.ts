import { listen, type UnlistenFn } from '@tauri-apps/api/event'
import { getCurrentWindow } from '@tauri-apps/api/window'

export type MenuActions = {
  onNewFile: () => void
  onOpen: () => void
  onSave: () => void
  onSaveAs: () => void
  onExportPdf: () => void
  onExportHtml: () => void
  onShowStats: () => void
  onFind: () => void
  // Focus Mode / Typewriter 토글: Rust가 체크마크를 뒤집고 "새 상태(boolean)"를 보내므로
  // 콜백은 그 값을 그대로 받아 적용한다(프런트가 로컬에서 토글을 추측하지 않음).
  onToggleFocusMode: (on: boolean) => void
  onToggleTypewriter: (on: boolean) => void
  onOpenFromOs: (path: string) => void
  onQuit: () => void
}

/**
 * Tauri 메뉴 이벤트와 OS 파일 열기 이벤트를 콜백으로 라우팅.
 * Tauri-specific 통합을 view·service에서 분리한다.
 *
 * `listen()`은 cleanup 콜백(UnlistenFn)을 반환하는데, start() 안에서 이를 모아두고
 * stop()에서 일괄 해제할 수 있게 한다. 현재 앱에서는 singleton이라 실제 호출되진
 * 않지만, dev HMR이나 향후 재초기화 시 stale listener 누적을 막는다.
 */
export class MenuBridge {
  private unlisteners: UnlistenFn[] = []

  constructor(private readonly actions: MenuActions) {}

  async start(): Promise<void> {
    const u = this.unlisteners
    // 멀티 창: Rust가 menu:* / open:file을 "포커스된 창"에만 emit_to(WebviewWindow{label})
    // 한다. 전역 listen(target: Any)은 그 targeted emit을 받지 못하므로, 이 창의 label을
    // target으로 지정해 "내 창으로 향한" 이벤트만 받는다. (전역 broadcast는 여전히 수신)
    const opts = { target: getCurrentWindow().label }
    u.push(await listen('menu:new_file', () => this.actions.onNewFile(), opts))
    u.push(await listen('menu:open', () => this.actions.onOpen(), opts))
    u.push(await listen('menu:save', () => this.actions.onSave(), opts))
    u.push(await listen('menu:save_as', () => this.actions.onSaveAs(), opts))
    u.push(await listen('menu:export_pdf', () => this.actions.onExportPdf(), opts))
    u.push(await listen('menu:export_html', () => this.actions.onExportHtml(), opts))
    u.push(await listen('menu:show_stats', () => this.actions.onShowStats(), opts))
    u.push(await listen('menu:find', () => this.actions.onFind(), opts))
    // 토글 이벤트는 payload로 새 boolean 상태를 싣고 온다(Rust가 체크마크와 함께 결정).
    u.push(
      await listen<boolean>('menu:focus_mode', (e) => this.actions.onToggleFocusMode(e.payload), opts),
    )
    u.push(
      await listen<boolean>('menu:typewriter', (e) => this.actions.onToggleTypewriter(e.payload), opts),
    )
    // Open Recent 클릭은 인덱스 이벤트로 받지 않는다. 메뉴 빌드/클릭 사이 목록 변경으로
    // 엉뚱한 파일이 열리는 race를 막기 위해, Rust가 클릭 순간 권위 있는 목록에서 실제 경로를
    // 해석해 OS 파일 열기와 동일한 "open:file"로 보낸다 → onOpenFromOs로 일원화 처리.
    u.push(
      await listen<string>(
        'open:file',
        (event) => {
          if (event.payload) this.actions.onOpenFromOs(event.payload)
        },
        opts,
      ),
    )
    // menu:quit은 Rust가 app.emit으로 "전 창"에 broadcast한다(EventTarget::Any →
    // target 지정 리스너에도 전달됨). 각 창이 받아 스스로 닫기(확인 포함)를 수행.
    u.push(await listen('menu:quit', () => this.actions.onQuit(), opts))
  }

  /** 등록된 모든 Tauri event listener 해제. 재초기화 또는 종료 정리용. */
  stop(): void {
    for (const unlisten of this.unlisteners) {
      try { unlisten() } catch { /* listener가 이미 해제됐을 수 있어 무시 */ }
    }
    this.unlisteners = []
  }
}
