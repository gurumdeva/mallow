import { listen } from '@tauri-apps/api/event'
import { MAX_RECENT } from './RecentFilesStore'

export type MenuActions = {
  onNewFile: () => void
  onOpen: () => void
  onSave: () => void
  onSaveAs: () => void
  onExportPdf: () => void
  onShowStats: () => void
  onRecentOpen: (idx: number) => void
  onOpenFromOs: (path: string) => void
}

/**
 * Tauri 메뉴 이벤트와 OS 파일 열기 이벤트를 콜백으로 라우팅.
 * Tauri-specific 통합을 view·service에서 분리한다.
 */
export class MenuBridge {
  constructor(private readonly actions: MenuActions) {}

  async start(): Promise<void> {
    await listen('menu:new_file', () => this.actions.onNewFile())
    await listen('menu:open', () => this.actions.onOpen())
    await listen('menu:save', () => this.actions.onSave())
    await listen('menu:save_as', () => this.actions.onSaveAs())
    await listen('menu:export_pdf', () => this.actions.onExportPdf())
    await listen('menu:show_stats', () => this.actions.onShowStats())
    for (let i = 0; i < MAX_RECENT; i++) {
      await listen(`menu:recent_${i}`, () => this.actions.onRecentOpen(i))
    }
    await listen<string>('open:file', (event) => {
      if (event.payload) this.actions.onOpenFromOs(event.payload)
    })
  }
}
