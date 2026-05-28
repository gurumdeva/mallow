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
  /**
   * 마지막으로 디스크에서 읽었거나 디스크에 쓴 원본 텍스트.
   * 외부 변경 감지의 기준선 — focus 시점에 디스크 내용과 이 값을 raw 비교한다.
   * (에디터가 markdown을 normalize할 수 있으므로 editor.getMarkdown()이 아니라
   *  실제 IO된 원본 문자열을 보관해야 오탐이 없다.)
   */
  private lastDiskContent: string | null = null
  /** syncFromDiskIfChanged 재진입 방지 (ask 다이얼로그가 열린 동안 focus 재발화 등). */
  private isSyncing = false

  constructor(
    private readonly doc: Document,
    private readonly editor: EditorController,
    private readonly recent: RecentFilesStore,
  ) {}

  /**
   * 열기 다이얼로그만 띄워 선택된 경로를 반환한다(로드는 하지 않음).
   * 멀티 창 모드에서는 "현재 창에 로드할지 / 새 창을 띄울지"를 호출부(main.ts)가
   * 결정하므로, 파일 선택과 로드를 분리한다. 취소 시 null.
   */
  async pickOpenPath(): Promise<string | null> {
    const selected = await openDialog({
      multiple: false,
      filters: [{ name: 'Markdown', extensions: ['md', 'markdown', 'txt'] }],
    })
    return typeof selected === 'string' ? selected : null
  }

  async openPath(path: string): Promise<void> {
    try {
      const content = await readTextFile(path)
      await this.editor.load(content)
      this.doc.setPath(path)
      this.doc.markSaved()
      this.recent.add(path)
      this.lastDiskContent = content
    } catch (e) {
      // 존재하지 않는 파일 등 — recent 목록에서 정리한 뒤 호출자(main.ts)가
      // toast를 띄울 수 있도록 에러를 다시 throw.
      this.recent.remove(path)
      throw e
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
    this.lastDiskContent = md
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
    this.lastDiskContent = md
  }

  /**
   * 윈도우가 다시 focus될 때 호출. 현재 파일이 외부 앱 등에서 변경됐는지
   * 디스크를 다시 읽어 마지막으로 본 내용(lastDiskContent)과 raw 비교한다.
   *
   * 분기:
   *  - 변경 없음 → no-op
   *  - 변경 O + 로컬 미수정 → 조용히 디스크 내용으로 reload
   *  - 변경 O + 로컬 수정 O(충돌) → 사용자에게 reload 여부 확인
   *
   * 엣지 케이스 방어:
   *  - 저장된 파일이 없으면(새 문서) skip
   *  - 파일이 외부에서 삭제/이동돼 읽기 실패 시 에디터 내용 유지 + 조용히 무시
   *  - ask 다이얼로그가 떠 있는 동안 focus 재발화 → isSyncing 가드로 재진입 차단
   *  - reload를 거절해도 lastDiskContent를 갱신해 같은 내용으로 재프롬프트되지 않게 함
   */
  async syncFromDiskIfChanged(): Promise<void> {
    if (this.isSyncing) return
    const path = this.doc.filePath
    if (!path) return // 새 문서(미저장)는 비교 대상 없음

    this.isSyncing = true
    try {
      let disk: string
      try {
        disk = await readTextFile(path)
      } catch {
        // 외부에서 삭제/이동됐거나 일시적 접근 불가. 에디터 내용은 그대로 두고
        // 조용히 넘어간다(다음 focus에서 재시도). 저장 시 파일이 다시 생성됨.
        return
      }

      if (disk === this.lastDiskContent) return // 외부 변경 없음

      if (!this.doc.isModified) {
        // 로컬 편집이 없으므로 손실 위험 없이 바로 디스크 내용 반영.
        await this.editor.load(disk)
        this.doc.markSaved() // load가 emit한 'change'로 dirty 표시된 것을 되돌림
        this.lastDiskContent = disk
      } else {
        // 로컬 편집 + 외부 변경이 동시에 존재 → 한쪽을 버려야 하므로 사용자 확인.
        const reload = await ask(
          '이 파일이 다른 곳에서 변경되었습니다.\n디스크의 내용으로 다시 불러올까요?\n편집 중인 내용은 사라집니다.',
          { title: '외부 변경 감지', kind: 'warning' },
        )
        if (reload) {
          await this.editor.load(disk)
          this.doc.markSaved()
        }
        // 거절하더라도 "이 디스크 버전은 확인함"으로 기록 → 동일 내용 재프롬프트 방지.
        this.lastDiskContent = disk
      }
    } finally {
      this.isSyncing = false
    }
  }
}
