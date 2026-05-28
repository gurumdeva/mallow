import { invoke } from '@tauri-apps/api/core'

export const MAX_RECENT = 5

/**
 * 최근 파일 목록 접근자.
 *
 * 단일 소스(authoritative)는 Rust(`RecentFiles`, Mutex + recent.json 영속)이고
 * 이 클래스는 얇은 async 래퍼다. 창마다 localStorage로 들고 있으면 공유 저장소의
 * read-modify-write가 창 사이에서 경쟁해 항목이 유실될 수 있으므로(lost update),
 * 모든 추가/제거/조회를 Rust 커맨드로 직렬화한다. 메뉴 동기화도 Rust가 직접 한다.
 */
export class RecentFilesStore {
  async list(): Promise<string[]> {
    try {
      return await invoke<string[]>('recent_get')
    } catch {
      return []
    }
  }

  async add(path: string): Promise<void> {
    try {
      await invoke('recent_add', { path })
    } catch {
      /* 영속/메뉴 갱신 실패는 치명적이지 않으므로 무시 */
    }
  }

  async remove(path: string): Promise<void> {
    try {
      await invoke('recent_remove', { path })
    } catch {
      /* 무시 */
    }
  }
}
