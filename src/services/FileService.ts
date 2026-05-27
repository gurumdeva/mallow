import { ask, open as openDialog, save as saveDialog } from '@tauri-apps/plugin-dialog'
import { readTextFile, writeTextFile } from '@tauri-apps/plugin-fs'
import { Document } from '../domain/Document'
import { EditorController } from '../editor/EditorController'
import { RecentFilesStore } from './RecentFilesStore'

/**
 * 파일 IO 흐름(open/save/new)을 조립하는 application service.
 * Document·Editor·RecentFilesStore를 함께 mutate한다.
 */
export class FileService {
  constructor(
    private readonly doc: Document,
    private readonly editor: EditorController,
    private readonly recent: RecentFilesStore,
  ) {}

  async newFile(): Promise<void> {
    if (!(await this.confirmDiscard('새 문서를 열까요?'))) return
    await this.editor.load('')
    this.doc.resetToNew()
  }

  async open(): Promise<void> {
    if (!(await this.confirmDiscard('다른 파일을 열까요?'))) return
    const selected = await openDialog({
      multiple: false,
      filters: [{ name: 'Markdown', extensions: ['md', 'markdown', 'txt'] }],
    })
    if (typeof selected !== 'string') return
    await this.openPath(selected)
  }

  async openRecent(idx: number): Promise<void> {
    const path = this.recent.list()[idx]
    if (!path) return
    if (!(await this.confirmDiscard('다른 파일을 열까요?'))) return
    await this.openPath(path)
  }

  async openPath(path: string): Promise<void> {
    try {
      const content = await readTextFile(path)
      await this.editor.load(content)
      this.doc.setPath(path)
      this.doc.markSaved()
      this.recent.add(path)
    } catch (e) {
      console.error('open failed:', e)
      this.recent.remove(path)
    }
  }

  async save(): Promise<void> {
    let path = this.doc.filePath
    if (!path) {
      const selected = await saveDialog({
        defaultPath: this.doc.filename,
        filters: [{ name: 'Markdown', extensions: ['md'] }],
      })
      if (!selected) return
      path = selected
    }
    const md = this.editor.getMarkdown()
    await writeTextFile(path, md)
    this.doc.setPath(path)
    this.doc.markSaved()
    this.recent.add(path)
  }

  async saveAs(): Promise<void> {
    const selected = await saveDialog({
      defaultPath: this.doc.filename,
      filters: [{ name: 'Markdown', extensions: ['md'] }],
    })
    if (!selected) return
    const md = this.editor.getMarkdown()
    await writeTextFile(selected, md)
    this.doc.setPath(selected)
    this.doc.markSaved()
    this.recent.add(selected)
  }

  private async confirmDiscard(question: string): Promise<boolean> {
    if (!this.doc.isModified) return true
    return await ask(`저장하지 않은 변경 사항이 있습니다.\n${question}`, {
      title: '저장되지 않은 변경 사항',
      kind: 'warning',
    })
  }
}
