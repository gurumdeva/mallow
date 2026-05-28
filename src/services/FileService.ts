import { ask, open as openDialog, save as saveDialog } from '@tauri-apps/plugin-dialog'
import { readTextFile, writeTextFile } from '@tauri-apps/plugin-fs'
import { invoke } from '@tauri-apps/api/core'
import { Document } from '../domain/Document'
import { EditorController } from '../editor/EditorController'
import { RecentFilesStore } from './RecentFilesStore'
import { t } from '../i18n'

/**
 * 파일 IO(열기 다이얼로그·경로 열기·저장·외부 변경 동기화)를 조립하는 application service.
 * Document·Editor·RecentFilesStore를 함께 mutate한다.
 * (New/Open의 "현재 창 재사용 vs 새 창" 결정은 호출부 main.ts가 담당한다.)
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
  /** save/saveAs 재진입 방지 (빠른 ⌘S 연타·⌘S+버튼 동시 → 더블 다이얼로그/쓰기 차단). */
  private isSaving = false

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

  /**
   * popover에서 입력한 새 파일명을 적용한다.
   *  - 저장 전(새 문서, filePath 없음): 표시명만 변경 → 다음 저장 다이얼로그 기본값.
   *  - 저장됨: 같은 디렉터리에서 디스크 파일을 실제로 rename하고 경로·recent를 갱신.
   * 이름이 무효(base 비음)이거나 기존과 같으면 무시. rename 실패는 호출자가 toast.
   */
  async applyRename(name: string): Promise<void> {
    const newName = Document.normalizeFilename(name)
    if (!newName) return

    const oldPath = this.doc.filePath
    if (!oldPath) {
      this.doc.rename(name) // 아직 저장 안 된 새 문서 → 표시명만
      return
    }
    if (newName === this.doc.filename) return // 변경 없음

    const slash = oldPath.lastIndexOf('/')
    const newPath = oldPath.slice(0, slash + 1) + newName
    await invoke('rename_file', { oldPath, newPath })
    await this.recent.remove(oldPath)
    this.doc.setPath(newPath) // filename + path 갱신
    await this.recent.add(newPath)
    // 내용은 그대로이므로 lastDiskContent는 유지.
  }

  async openPath(path: string): Promise<void> {
    // 읽기(=파일 존재 확인)만 분리해 catch. 읽기 실패일 때만 recent에서 정리하고
    // 호출자(main.ts)가 toast를 띄우도록 rethrow한다. editor.load 등 읽기 이후
    // 단계가 실패해도 파일 자체는 유효하므로 recent에서 지우지 않는다.
    let content: string
    try {
      content = await readTextFile(path)
    } catch (e) {
      await this.recent.remove(path)
      throw e
    }
    await this.editor.load(content)
    this.doc.setPath(path)
    this.doc.markSaved()
    await this.recent.add(path)
    this.lastDiskContent = content
  }

  async save(): Promise<void> {
    if (this.isSaving) return
    this.isSaving = true
    try {
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
      await this.recent.add(path)
      this.lastDiskContent = md
    } finally {
      this.isSaving = false
    }
  }

  async saveAs(): Promise<void> {
    if (this.isSaving) return
    this.isSaving = true
    try {
      const selected = await saveDialog({
        defaultPath: this.doc.filename,
        filters: [{ name: 'Markdown', extensions: ['md'] }],
      })
      if (!selected) return
      const md = this.editor.getMarkdown()
      await writeTextFile(selected, md)
      this.doc.setPath(selected)
      this.doc.markSaved()
      await this.recent.add(selected)
      this.lastDiskContent = md
    } finally {
      this.isSaving = false
    }
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
      const baseline = this.lastDiskContent
      let disk: string
      try {
        disk = await readTextFile(path)
      } catch {
        // 외부에서 삭제/이동됐거나 일시적 접근 불가. 에디터 내용은 그대로 두고
        // 조용히 넘어간다(다음 focus에서 재시도). 저장 시 파일이 다시 생성됨.
        return
      }

      // readTextFile await 동안 save가 끼어들어 기준선/디스크를 갱신했을 수 있다.
      // 그 경우 위에서 읽은 disk는 stale → 이 sync를 폐기해야, 방금 저장한 내용을
      // 옛 디스크 내용으로 되돌리는 race(데이터 손실)를 막는다.
      if (this.lastDiskContent !== baseline) return

      if (disk === this.lastDiskContent) return // 외부 변경 없음

      if (!this.doc.isModified) {
        // 로컬 편집이 없으므로 손실 위험 없이 바로 디스크 내용 반영.
        await this.editor.load(disk)
        this.doc.markSaved() // load가 emit한 'change'로 dirty 표시된 것을 되돌림
        this.lastDiskContent = disk
      } else {
        // 로컬 편집 + 외부 변경이 동시에 존재 → 한쪽을 버려야 하므로 사용자 확인.
        const reload = await ask(
          t('dialog.externalChange.body', { name: this.doc.filename }),
          { title: t('dialog.externalChange.title'), kind: 'warning' },
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
