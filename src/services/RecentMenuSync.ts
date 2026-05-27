import { invoke } from '@tauri-apps/api/core'
import { RecentFilesStore } from './RecentFilesStore'

/**
 * RecentFilesStore를 구독해 Tauri 네이티브 메뉴와 동기화한다.
 * Store의 책임(영구 저장)과 메뉴 동기화 책임을 분리.
 */
export class RecentMenuSync {
  constructor(private readonly store: RecentFilesStore) {
    this.store.on('changed', () => this.sync())
    // 시작 시 한 번 강제 동기화
    void this.sync()
  }

  async sync(): Promise<void> {
    try {
      await invoke('update_recent_files', { paths: this.store.list() })
    } catch (e) {
      console.error('recent menu sync failed:', e)
    }
  }
}
