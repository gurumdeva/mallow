import { ask, open as openDialog, save as saveDialog } from '@tauri-apps/plugin-dialog'
import { readTextFile } from '@tauri-apps/plugin-fs'
import { invoke } from '@tauri-apps/api/core'
import { Document } from '../domain/Document'
import { EditorController } from '../editor/EditorController'
import { RecentFilesStore } from './RecentFilesStore'
import { splitFrontmatter, composeFrontmatter } from './frontmatter'
import { t } from '../i18n'

/**
 * 저장(write) 직후 "문서를 saved로 표시해도 되는가"를 결정하는 순수 함수.
 *
 * 배경: write는 비동기(await writeTextFile)다. 그 사이에 사용자가 계속 타이핑하면
 * 디스크에 쓴 내용(written)보다 에디터의 현재 내용(current)이 더 새롭다. 이때
 * 무조건 markSaved()를 하면, 디스크에 반영되지 않은 그 최신 편집의 dirty 플래그까지
 * 지워져 자동 저장이 다시 발화하지 않고 → 에디터가 디스크보다 영원히 앞선 채 손실된다.
 * (doc.isModified는 Milkdown markdownUpdated의 trailing 200ms debounce라 타이핑 도중엔
 *  stale-false일 수 있어 플래그로 판단하면 안 된다 → 실제 내용으로 판단한다.)
 *
 * 규칙: write에 넣은 내용과 지금 에디터 내용이 "그대로 같을 때"만 true.
 *  - true  → markSaved() + lastDiskContent = written (방금 쓴 내용이 곧 디스크 내용)
 *  - false → dirty 유지 (write 도중 더 친 내용이 있음 → 후속 저장이 최신 내용을 다시 쓴다)
 */
export function shouldMarkSaved(written: string, current: string): boolean {
  return written === current
}

/**
 * 외부 변경 동기화(syncFromDiskIfChanged)에서 "무엇을 할지"를 결정하는 순수 함수.
 *
 * 배경: focus 시점에 디스크를 다시 읽어(diskText) 마지막으로 IO한 원본(lastDiskContent)과
 * 비교한다. 외부 변경이 있을 때 "조용히 reload" vs "사용자 확인(prompt)"을 가르는 기준은
 * doc.isModified가 아니라 "에디터 현재 내용이 마지막 IO 내용과 같은가"여야 한다.
 * isModified는 trailing debounce라 타이핑 도중엔 stale-false → 그 순간 외부 변경이 들어오면
 * 조용히 덮어써 진행 중 편집이 손실된다. 실제 내용(editorText)으로 판단해 그 손실을 막는다.
 *
 * 반환:
 *  - 'noop'   → diskText === lastDiskContent: 외부 변경 없음(할 일 없음).
 *  - 'silent' → 외부 변경 O + editorText === lastDiskContent(로컬 편집 없음): 손실 위험 없이 reload.
 *  - 'prompt' → 외부 변경 O + 로컬 편집 O(editorText !== lastDiskContent): 한쪽을 버려야 하므로 확인.
 *
 * 세 인자 모두 string이다. lastDiskContent는 저장/열기 후에만 의미가 있으므로(null인 동안엔
 * 비교 기준이 없다) 호출부가 null을 걸러낸 뒤 이 함수를 부른다(아래 syncFromDiskIfChanged 참조).
 */
export type SyncDecision = 'noop' | 'silent' | 'prompt'
export function decideSyncAction(
  editorText: string,
  lastDiskContent: string,
  diskText: string,
): SyncDecision {
  if (diskText === lastDiskContent) return 'noop' // 외부 변경 없음
  // 외부 변경 O. 로컬 편집이 없으면(에디터 = 마지막 IO 내용) 안전하게 조용히 reload.
  if (editorText === lastDiskContent) return 'silent'
  // 외부 변경 + 로컬 편집 동시 존재 → 충돌 → 사용자 확인.
  return 'prompt'
}

/** rename 실패 사유. 호출부(main.ts)가 code로 사유별 지역화 토스트를 고른다. */
export type RenameErrorCode = 'invalid' | 'exists'
export class RenameError extends Error {
  constructor(readonly code: RenameErrorCode) {
    super(code)
    this.name = 'RenameError'
  }
}

/**
 * 파일 열기가 "읽기 실패"로 끝났음을 알리는 에러. 이 시점에 해당 경로는 이미
 * 최근 목록(권위 있는 Rust 목록)에서 제거됐다 → 호출부(main.ts)가 일반 오류 대신
 * "더 이상 존재하지 않아 최근 목록에서 제거함" 토스트를 띄우도록 구분한다.
 * (삭제/이동된 파일을 recent에서 클릭한 흔한 경우를 사용자에게 명확히 알린다.)
 */
export class OpenError extends Error {
  constructor(readonly cause: unknown) {
    super('open-failed')
    this.name = 'OpenError'
  }
}

/**
 * 저장/다른 이름으로 저장이 "다른 창에 이미 열려 있는 파일"을 대상으로 했을 때 던진다.
 * 그대로 쓰면 두 창이 같은 파일을 각자 자동 저장해 서로의 편집을 덮어쓰는 cross-window
 * lost update(데이터 손실)가 되므로, 쓰기 전에 막고 호출부(main.ts)가 사유별 토스트를 띄운다.
 * fileName은 안내 토스트에 쓸 표시용 파일명(경로의 마지막 구성요소).
 */
export class SaveConflictError extends Error {
  readonly fileName: string
  constructor(readonly path: string) {
    super('save-conflict')
    this.name = 'SaveConflictError'
    this.fileName = path.split('/').pop() ?? path
  }
}

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
  /**
   * 현재 문서의 선두 YAML 프론트매터(`---`…`---`) 원문. 에디터(Milkdown AST)는 프론트매터를
   * HR+본문으로 오인해 직렬화 시 깨뜨리므로, 열 때 떼어내 여기 원문 그대로 보관하고 본문만
   * 에디터에 싣는다. 디스크에 쓸 때만 toDiskContent()가 다시 앞에 붙인다. 프론트매터가 없으면 ''.
   * (제목 없는 새 문서·환영 문서는 FileService를 거치지 않고 본문만 load되므로 '' 그대로다.)
   */
  private frontmatter = ''
  /**
   * 제목 없는(미저장) 문서의 "깨끗한 기준" 내용. 시작 시 환영 문서/빈 문서 등 최초 콘텐츠를
   * 담아 두고(captureBaseline), hasUnsavedChanges가 미저장 문서의 미저장 편집을 판단하는 데 쓴다.
   * (lastDiskContent는 디스크 IO가 있어야 의미가 있어 미저장 문서엔 null이므로 별도 기준이 필요하다.)
   */
  private baselineContent = ''
  /** syncFromDiskIfChanged 재진입 방지 (ask 다이얼로그가 열린 동안 focus 재발화 등). */
  private isSyncing = false
  /** save/saveAs 재진입 방지 (빠른 ⌘S 연타·⌘S+버튼 동시 → 더블 다이얼로그/쓰기 차단). */
  private isSaving = false
  /**
   * 진행 중인 save/saveAs의 promise. rename이 시작 전에 이를 await해, "디스크 rename과
   * 동시에 옛 경로로 쓰기가 진행 중"인 race를 없앤다(save #4). 진행 중이 없으면 null.
   */
  private savePromise: Promise<void> | null = null
  /**
   * rename 진행 중 플래그. true인 동안 save/saveAs는 즉시 early-return해, rename이 디스크
   * 경로를 old→new로 바꾸는 창에서 자동 저장이 stale한 doc.filePath(=old)로 써 옛 파일을
   * 되살리거나 최신 편집을 옛 파일에 가두는 race(#4)를 막는다.
   */
  private isRenaming = false

  constructor(
    private readonly doc: Document,
    private readonly editor: EditorController,
    private readonly recent: RecentFilesStore,
  ) {}

  /**
   * 현재 "깨끗한 기준" 내용을 에디터의 현재 직렬화 결과로 고정한다. 시작 시 최초 콘텐츠가
   * 자리잡은 직후(환영/빈/복원 문서)에 main.ts가 호출한다. 이후 hasUnsavedChanges가 이 기준과
   * 비교해 미저장 편집을 판단한다. (열기/저장/리로드 시에는 각 IO 지점에서 함께 갱신된다.)
   */
  captureBaseline(): void {
    this.baselineContent = this.editor.getMarkdown()
  }

  /**
   * 마지막으로 "깨끗했던" 시점 대비 미저장 편집이 있는지 실제 내용 기준으로 판단한다(창 닫기·종료
   * 확인용). doc.isModified는 markdownUpdated의 trailing 200ms debounce라 타이핑 직후엔 stale-false일
   * 수 있어, 그 플래그로 닫기/종료를 판단하면 방금 친 내용이 확인 없이 사라진다(데이터 손실).
   * shouldMarkSaved/decideSyncAction과 동일하게 에디터의 현재 직렬화 내용을 직접 비교한다.
   * 기준(baselineContent)은 "정규화된 에디터 출력"이라, 외부에서 만든 .md를 열어 에디터가 마크다운을
   * 정규화하더라도 편집이 없으면 동일 → 닫을 때 거짓 미저장 확인이 뜨지 않는다.
   */
  hasUnsavedChanges(): boolean {
    return this.editor.getMarkdown() !== this.baselineContent
  }

  /**
   * 디스크에 쓸 전체 내용 = 보관 중인 프론트매터 + 에디터 본문. 외부 변경 비교/저장에서 "에디터가
   * 디스크에 만들 내용"으로 이걸 쓴다. 에디터의 getMarkdown()은 본문만이라, 프론트매터를 가진
   * 파일에서 디스크 원본과 직접 비교하면 프론트매터만큼 어긋나기 때문이다.
   */
  private toDiskContent(): string {
    return composeFrontmatter(this.frontmatter, this.editor.getMarkdown())
  }

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
    // 빈 이름이나 경로 분리자 포함(폴더 탈출 시도) → 무효. 호출부가 안내 토스트를 띄운다.
    if (!newName) throw new RenameError('invalid')

    // 저장 전(새 문서)은 디스크 rename이 없고 표시명만 바꾼다 → 가드/직렬화 불필요.
    if (!this.doc.filePath) {
      this.doc.rename(name)
      return
    }

    // ── save와 직렬화(#4) ──────────────────────────────────────────────
    // 진행 중인 save가 있으면 끝나길 기다린다. 그 save는 (아직 존재하는) 옛 경로로 쓰기를
    // 마치므로 내용 손실이 없다. 그 뒤 isRenaming을 세워 새 자동 저장이 디스크 rename 창에서
    // stale 경로로 쓰는 것을 막는다. (save 자체의 에러는 그 호출부에서 이미 처리되므로 여기선 무시.)
    const pendingSave = this.savePromise
    if (pendingSave) await pendingSave.catch(() => {})

    this.isRenaming = true
    try {
      // oldPath/filename은 in-flight save를 기다린 "뒤"에 읽어, 그 사이 경로가 바뀌었을
      // 가능성(예: 직전 saveAs)까지 반영한다.
      const oldPath = this.doc.filePath
      if (!oldPath) {
        this.doc.rename(name) // 대기 중 경로가 사라진 비정상 경우 → 표시명만
        return
      }
      if (newName === this.doc.filename) return // 변경 없음

      const slash = oldPath.lastIndexOf('/')
      const newPath = oldPath.slice(0, slash + 1) + newName
      // Rust rename_file이 (1) 같은 폴더 내인지 (2) 대상이 이미 있는지 검사해 거부할 수 있다.
      // 거부 코드를 RenameError로 변환해 호출부가 사유별 토스트를 띄우게 한다.
      try {
        await invoke('rename_file', { oldPath, newPath })
      } catch (e) {
        const code = String(e)
        if (code === 'exists') throw new RenameError('exists')
        if (code === 'invalid') throw new RenameError('invalid')
        throw e // 그 밖의 OS 오류는 그대로(상위가 일반 rename 오류 토스트)
      }
      // 디스크 rename 직후 await 없이 곧바로 경로를 갱신한다(#4의 핵심): rename과 setPath
      // 사이에 yield가 없어, 설령 가드를 벗어난 save가 있더라도 stale 경로를 노릴 수 없다.
      this.doc.setPath(newPath) // filename + path 갱신
      // recent 정리는 경로 갱신 "뒤"에 둔다(여기서 await가 일어나도 doc.filePath는 이미 newPath).
      await this.recent.remove(oldPath)
      await this.recent.add(newPath)
      // 내용은 그대로이므로 lastDiskContent는 유지.
    } finally {
      this.isRenaming = false
    }
  }

  async openPath(path: string): Promise<void> {
    // 읽기(=파일 존재 확인)만 분리해 catch. 읽기 실패는 보통 파일이 삭제/이동된 경우다
    // → 권위 있는 최근 목록(Rust)에서 그 경로를 제거하고(recent_remove가 영속+메뉴 재빌드),
    // OpenError로 rethrow해 호출자(main.ts)가 "최근 목록에서 제거함" 토스트를 띄우게 한다.
    // editor.load 등 읽기 이후 단계의 실패는 파일 자체는 유효하므로 recent를 건드리지 않는다.
    let content: string
    try {
      content = await readTextFile(path)
    } catch (e) {
      await this.recent.remove(path)
      throw new OpenError(e)
    }
    // 선두 프론트매터를 떼어내 본문만 에디터에 싣고, 프론트매터는 원문 그대로 보관한다
    // (Milkdown이 프론트매터를 깨뜨리지 않도록 — 저장 시 toDiskContent가 다시 붙인다).
    const { frontmatter, body } = splitFrontmatter(content)
    this.frontmatter = frontmatter
    await this.editor.load(body)
    this.doc.setPath(path)
    this.doc.markSaved()
    await this.recent.add(path)
    // lastDiskContent는 "디스크 원본 전체"(프론트매터 포함)를 보관한다 — 외부에서 프론트매터만
    // 바뀌어도 감지하기 위해. 본문 기준선(baselineContent)은 에디터 본문이다.
    this.lastDiskContent = content
    this.baselineContent = this.editor.getMarkdown() // 정규화된 기준(외부 .md 정규화 오탐 방지)
  }

  /**
   * 대상 경로가 "다른 창"에 이미 열려 있으면 SaveConflictError를 던진다(쓰기 전 가드).
   * 파일 "열기"의 중복 창은 focus_or_claim이 막지만, Save As와 제목 없는 문서의 최초 저장은
   * 그 경로를 거치지 않아 두 창이 같은 파일을 덮어쓰는 lost update가 날 수 있다. 그 지점에서만
   * 호출한다(이미 자기 창이 소유한 경로로의 자동 저장/⌘S는 검사하지 않는다 — Rust가 호출 창을
   * 제외하므로 통과하지만, 불필요한 IPC를 피하려 다이얼로그로 새 경로를 고른 지점에서만 부른다).
   */
  private async assertNotOpenElsewhere(path: string): Promise<void> {
    const conflict = await invoke<boolean>('path_open_in_other_window', { path }).catch(() => false)
    if (conflict) throw new SaveConflictError(path)
  }

  async save(): Promise<void> {
    // rename 진행 중이면 디스크 경로가 old→new로 바뀌는 중이라 stale 경로로 쓸 위험이 있다.
    // 자동 저장이 끼어들어도 여기서 막고, rename 종료 후 dirty가 남아 있으면 다시 발화한다.
    if (this.isSaving || this.isRenaming) return
    this.isSaving = true
    // 진행 중 promise를 노출해 applyRename이 await할 수 있게 한다(동시 쓰기 race 차단).
    const run = this.runSave().finally(() => {
      this.isSaving = false
      this.savePromise = null
    })
    this.savePromise = run
    return run
  }

  private async runSave(): Promise<void> {
    let path = this.doc.filePath
    if (!path) {
      const selected = await saveDialog({
        defaultPath: this.doc.filename,
        filters: [{ name: 'Markdown', extensions: ['md'] }],
      })
      if (!selected) return
      // 다른 창에 이미 열린 파일 위로 최초 저장하면 두 창이 같은 파일을 자동 저장해 서로를
      // 덮어쓴다(cross-window lost update). 그 경로는 거부한다(호출부가 안내 토스트를 띄운다).
      await this.assertNotOpenElsewhere(selected)
      path = selected
    }
    const md = this.editor.getMarkdown()
    // 디스크엔 보관 중인 프론트매터를 본문 앞에 다시 붙여 쓴다(에디터엔 본문만 있다).
    const written = composeFrontmatter(this.frontmatter, md)
    // 원자적 저장(임시 파일 → rename): 쓰는 도중 강제 종료돼도 원본이 찢기지 않는다.
    await invoke('write_file_atomic', { path, content: written })
    this.doc.setPath(path)
    await this.recent.add(path)
    // write는 비동기다. await 동안 사용자가 더 타이핑했다면 에디터 본문이 디스크보다
    // 새롭다 → markSaved()로 dirty를 지우면 그 최신 편집이 자동 저장에서 누락된다.
    // 실제 본문으로 비교해, "쓴 본문 == 현재 본문"일 때만 saved 처리하고 기준선을 갱신한다.
    // 다르면 dirty를 유지해 기존 자동 저장 'changed' 경로가 최신 내용을 다시 쓰게 둔다.
    // (lastDiskContent는 "실제로 쓴 전체 내용"일 때만 갱신 — 외부 변경 비교의 기준선.)
    if (shouldMarkSaved(md, this.editor.getMarkdown())) {
      this.doc.markSaved()
      this.lastDiskContent = written
      this.baselineContent = md // 방금 쓴 본문(=현재 에디터 본문)이 새 깨끗한 기준
    }
  }

  async saveAs(): Promise<void> {
    if (this.isSaving || this.isRenaming) return
    this.isSaving = true
    const run = this.runSaveAs().finally(() => {
      this.isSaving = false
      this.savePromise = null
    })
    this.savePromise = run
    return run
  }

  private async runSaveAs(): Promise<void> {
    const selected = await saveDialog({
      defaultPath: this.doc.filename,
      filters: [{ name: 'Markdown', extensions: ['md'] }],
    })
    if (!selected) return
    // Save As가 다른 창에 열린 파일을 덮어써 cross-window lost update가 나는 것을 막는다.
    await this.assertNotOpenElsewhere(selected)
    const md = this.editor.getMarkdown()
    // 디스크엔 보관 중인 프론트매터를 본문 앞에 다시 붙여 쓴다(에디터엔 본문만 있다).
    const written = composeFrontmatter(this.frontmatter, md)
    // 원자적 저장(임시 파일 → rename): 쓰는 도중 강제 종료돼도 원본이 찢기지 않는다.
    await invoke('write_file_atomic', { path: selected, content: written })
    this.doc.setPath(selected)
    await this.recent.add(selected)
    // save()와 동일한 본문 기반 재조정: write await 동안 사용자가 더 친 내용이 있으면
    // dirty를 유지해(자동 저장이 새 경로로 최신 내용을 다시 쓰게) 손실을 막는다.
    if (shouldMarkSaved(md, this.editor.getMarkdown())) {
      this.doc.markSaved()
      this.lastDiskContent = written
      this.baselineContent = md // 방금 쓴 본문이 새 깨끗한 기준
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
      // path가 설정돼 있으면(openPath/save/saveAs를 거쳤으면) lastDiskContent는 항상 non-null.
      // 기준선이 없으면 외부 변경을 신뢰성 있게 판단할 수 없어, 손실 위험을 피해 보수적으로 skip.
      if (baseline === null) return

      // reload/prompt 결정은 debounce된 doc.isModified가 아니라 "실제 에디터 내용"으로 한다.
      // (타이핑 도중 isModified는 stale-false라, 그 순간 외부 변경이 조용히 덮어쓸 수 있다.)
      // 에디터가 "디스크에 만들 내용"(프론트매터 + 본문)으로 디스크 원본과 비교한다.
      const action = decideSyncAction(this.toDiskContent(), baseline, disk)
      if (action === 'noop') return // 외부 변경 없음

      if (action === 'silent') {
        // 조합(IME) 중이면 getMarkdown()에 아직 확정되지 않은 조합 글자가 빠져 'silent'로 오판될 수
        // 있다. 그 상태로 load하면 조합 입력이 사라지므로, 조합이 끝난 다음 기회(다음 focus)로 미룬다.
        if (this.editor.isComposing()) return
        // 로컬 편집이 없으므로(에디터 내용 == 마지막 IO 내용) 손실 위험 없이 디스크 내용 반영.
        // 디스크의 프론트매터를 다시 떼어내 보관하고 본문만 에디터에 싣는다(외부에서 프론트매터가
        // 바뀌었을 수 있으므로 함께 갱신).
        {
          const reloaded = splitFrontmatter(disk)
          this.frontmatter = reloaded.frontmatter
          await this.editor.load(reloaded.body)
        }
        this.doc.markSaved() // load가 emit한 'change'로 dirty 표시된 것을 되돌림
        this.lastDiskContent = disk
        this.baselineContent = this.editor.getMarkdown() // reload한 본문이 새 깨끗한 기준
      } else {
        // 로컬 편집 + 외부 변경이 동시에 존재 → 한쪽을 버려야 하므로 사용자 확인.
        const reload = await ask(
          t('dialog.externalChange.body', { name: this.doc.filename }),
          { title: t('dialog.externalChange.title'), kind: 'warning' },
        )
        if (reload) {
          // 디스크 버전 수용: 프론트매터를 다시 떼어내 보관하고 본문만 싣는다.
          const reloaded = splitFrontmatter(disk)
          this.frontmatter = reloaded.frontmatter
          await this.editor.load(reloaded.body)
          this.doc.markSaved()
          this.baselineContent = this.editor.getMarkdown() // 디스크 본문 수용 → 새 기준
        }
        // 거절하더라도 "이 디스크 버전은 확인함"으로 기록 → 동일 내용 재프롬프트 방지.
        // (거절 시 baselineContent는 그대로 둬, 사용자가 지킨 로컬 편집이 여전히 "미저장"으로 남는다.)
        this.lastDiskContent = disk
      }
    } finally {
      this.isSyncing = false
    }
  }
}
