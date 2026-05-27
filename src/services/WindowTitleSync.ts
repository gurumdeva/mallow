import { getCurrentWindow } from '@tauri-apps/api/window'
import { Document } from '../domain/Document'

/**
 * Document.displayTitle을 macOS 네이티브 윈도우 타이틀에 동기화.
 */
export class WindowTitleSync {
  private readonly win = getCurrentWindow()

  constructor(private readonly doc: Document) {
    this.doc.on('changed', () => this.sync())
    this.sync()
  }

  private sync(): void {
    this.win.setTitle(this.doc.displayTitle).catch(() => {})
  }
}
