import { EventEmitter } from '../domain/EventEmitter'

const STORAGE_KEY = 'recent-files'
export const MAX_RECENT = 5

/**
 * 최근 파일 목록의 영구 저장 (localStorage).
 * 메뉴 동기화는 RecentMenuSync에서 별도로 담당한다.
 */
export class RecentFilesStore extends EventEmitter {
  list(): string[] {
    try {
      const raw = localStorage.getItem(STORAGE_KEY)
      if (!raw) return []
      const arr = JSON.parse(raw)
      return Array.isArray(arr) ? arr.slice(0, MAX_RECENT) : []
    } catch {
      return []
    }
  }

  add(path: string): void {
    const existing = this.list()
    const next = [path, ...existing.filter((p) => p !== path)].slice(0, MAX_RECENT)
    this.save(next)
  }

  remove(path: string): void {
    const next = this.list().filter((p) => p !== path)
    this.save(next)
  }

  private save(paths: string[]): void {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(paths))
    this.emit('changed')
  }
}
