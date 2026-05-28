import './style.css'
import { ask } from '@tauri-apps/plugin-dialog'
import { getCurrentWindow } from '@tauri-apps/api/window'
import { WebviewWindow } from '@tauri-apps/api/webviewWindow'
import { invoke } from '@tauri-apps/api/core'

import { Document } from './domain/Document'
import { UIState } from './domain/UIState'
import { EditorController } from './editor/EditorController'
import { StatsCalculator } from './analysis/StatsCalculator'
import { TocExtractor } from './analysis/TocExtractor'
import { RecentFilesStore } from './services/RecentFilesStore'
import { WindowTitleSync } from './services/WindowTitleSync'
import { PdfExporter } from './services/PdfExporter'
import { FileService } from './services/FileService'
import { MenuBridge } from './services/MenuBridge'
import { TitleBarView } from './ui/TitleBarView'
import { FilenamePopover } from './ui/FilenamePopover'
import { InfoPopover } from './ui/InfoPopover'
import { StylePopover } from './ui/StylePopover'
import { ToastService, formatError } from './ui/ToastService'

const DEFAULT_MARKDOWN = ''

async function bootstrap(): Promise<void> {
  // ── State (single sources of truth) ─────────────────────
  const doc = new Document()
  const ui = new UIState()

  // ── Editor + Analysis ───────────────────────────────────
  const editor = new EditorController('#editor')
  const stats = new StatsCalculator()
  const toc = new TocExtractor()

  // ── Services ────────────────────────────────────────────
  // recent: 단일 소스는 Rust(RecentFiles, Mutex+영속); 여기선 async 래퍼. 메뉴 동기화도 Rust가 담당.
  const recent = new RecentFilesStore()
  new WindowTitleSync(doc)   // doc 구독해서 윈도우 타이틀 동기화
  const pdfExporter = new PdfExporter(doc)
  const fileService = new FileService(doc, editor, recent)

  // ── Toast 알림 인프라 + 공용 에러 핸들러 ────────────────
  // (View보다 먼저 정의: FilenamePopover의 rename 콜백에서 참조하기 때문)
  const toast = new ToastService()
  const reportError = (label: string) => (e: unknown) => {
    console.error(label, e)
    toast.error(`${label}: ${formatError(e)}`)
  }

  // ── Views (stateless, 상태는 doc/ui에서만 read) ──────────
  new TitleBarView(doc, ui)
  // 파일명 확정: 저장된 문서면 디스크 파일까지 rename, 새 문서면 표시명만 (FileService.applyRename).
  new FilenamePopover(doc, ui, (name) =>
    fileService.applyRename(name).catch(reportError('이름 변경')),
  )
  new InfoPopover(doc, ui, editor, stats, toc)
  new StylePopover(ui, editor)

  // ── Title bar의 PDF 아이콘 클릭 → export ─────────────────
  // 키보드 ⌘E는 MenuBridge가 처리하지만 버튼 클릭은 별도 wiring 필요.
  const btnPdf = document.getElementById('btn-pdf')
  btnPdf?.addEventListener('click', (e) => {
    e.stopPropagation()
    pdfExporter.export().catch(reportError('PDF 내보내기'))
  })

  // ── Wiring: editor 변경 → doc 수정 표시 ──────────────────
  editor.on('change', () => doc.markModified())

  // 이 창의 미저장 여부를 Rust에 보고한다(⌘Q 원자적 종료 판단용).
  // doc 'changed'는 자주 불리므로 isModified가 "실제로 바뀔 때"만 IPC를 보낸다.
  let reportedDirty = false
  doc.on('changed', () => {
    if (doc.isModified !== reportedDirty) {
      reportedDirty = doc.isModified
      invoke('set_window_dirty', { dirty: reportedDirty }).catch(() => {})
    }
  })

  const win = getCurrentWindow()

  // 새 창(doc-*)은 setup()의 다크 webview 처리를 받지 못하므로 여기서 적용한다.
  // (main 창은 setup에서 이미 처리됨 → 중복 방지로 제외)
  if (win.label !== 'main') invoke('apply_dark_webview').catch(() => {})

  // ── 멀티 창 헬퍼 ─────────────────────────────────────────
  // 단일 프로세스 + 여러 창. New/Open은 현재 문서를 덮지 않고 새 창을 띄운다.
  // 파일 경로는 URL 해시로 전달한다 — 해시는 asset 요청 경로에 포함되지 않아
  // 정적 파일 로드를 방해하지 않고, 새 창 bootstrap이 location.hash로 읽는다.
  const openDocumentWindow = async (filePath: string | null): Promise<void> => {
    const label = `doc-${crypto.randomUUID()}`
    const url = filePath ? `index.html#${encodeURIComponent(filePath)}` : 'index.html'
    // 현재 창에서 살짝 어긋난 위치(cascade)로 띄운다. 같은 위치에 완전히 겹쳐
    // "안 열린 것처럼" 보이는 걸 막는다(macOS 기본 계단식 배치와 동일한 UX).
    // 위치 조회는 logical 단위가 필요해 physical/scaleFactor로 환산한다.
    let position: { x: number; y: number } | undefined
    try {
      const phys = await win.outerPosition()
      const scale = await win.scaleFactor()
      position = { x: phys.x / scale + 32, y: phys.y / scale + 32 }
    } catch {
      /* 위치 조회 실패 시 기본 위치 (겹칠 수 있으나 기능엔 영향 없음) */
    }
    const w = new WebviewWindow(label, {
      url,
      title: '새 문서.md',
      width: 980,
      height: 760,
      titleBarStyle: 'overlay',
      hiddenTitle: true,
      backgroundColor: [28, 28, 30],
      ...(position ?? {}),
    })
    void w.once('tauri://error', (e) => reportError('새 창 열기')(e.payload))
  }

  // 파일 열기: 현재 창이 "깨끗한 새 문서"면 그 창을 재사용(in-place), 아니면 새 창.
  // 덕분에 앱을 갓 켠 빈 창에서 열면 빈 창이 남지 않고, 작업 중인 창은 보존된다.
  const handleOpenPath = (filePath: string): void => {
    if (doc.isPristine) {
      fileService.openPath(filePath).catch(reportError('파일 열기'))
    } else {
      openDocumentWindow(filePath).catch(reportError('새 창 열기'))
    }
  }

  // 현재 창 닫기: 미저장이면 확인 후 close_document_window로 이 창만 destroy한다.
  // 마지막 창이면 Rust RunEvent가 webview_windows 빈 것을 보고 앱을 종료한다.
  // 창 닫기 버튼/⌘W(onCloseRequested)와 ⌘Q(menu:quit) 양쪽에서 공용으로 쓴다.
  const closeThisWindow = async (): Promise<void> => {
    if (doc.isModified) {
      // 멀티 창에서 여러 확인창이 떠도 구분되도록 파일명을 함께 표시.
      const ok = await ask(
        `'${doc.filename}'에 저장하지 않은 변경 사항이 있습니다.\n정말 닫으시겠습니까?`,
        { title: '저장되지 않은 변경 사항', kind: 'warning' },
      )
      if (!ok) return // 취소 → 창 유지
    }
    invoke('close_document_window').catch(() => {})
  }

  // ── 초기 콘텐츠 로드 ────────────────────────────────────
  // 메뉴 리스너 활성화 전에 editor를 초기화해, init 중 메뉴 입력이
  // half-initialized Crepe에 dispatch되는 race를 막는다.
  await editor.initialize(DEFAULT_MARKDOWN)

  // ── Menu / OS file-open 이벤트 라우팅 ───────────────────
  // (Rust가 menu:* / open:file을 "포커스된 창"에만 emit하므로 여기 핸들러는
  //  현재 창에 대해서만 동작한다.)
  const menu = new MenuBridge({
    onNewFile: () => openDocumentWindow(null).catch(reportError('새 창 열기')),
    onOpen: () =>
      fileService
        .pickOpenPath()
        .then((p) => {
          if (p) handleOpenPath(p)
        })
        .catch(reportError('파일 열기')),
    onSave: () => fileService.save().catch(reportError('저장')),
    onSaveAs: () => fileService.saveAs().catch(reportError('다른 이름으로 저장')),
    onExportPdf: () => pdfExporter.export().catch(reportError('PDF 내보내기')),
    onShowStats: () => ui.toggleInfoPopover(),
    onRecentOpen: (i) => {
      recent
        .list()
        .then((list) => {
          const p = list[i]
          if (p) handleOpenPath(p)
        })
        .catch(reportError('최근 파일 열기'))
    },
    onOpenFromOs: (p) => handleOpenPath(p),
    // ⌘Q: 포커스 창이 코디네이터. 전체 미저장 문서 수를 Rust에서 조회해 통합 확인 1회 →
    // 종료(quit_app=app.exit) 또는 취소. 부분 종료(일부 창만 닫힘)가 발생하지 않는다.
    onQuit: () => {
      void (async () => {
        const n = await invoke<number>('dirty_window_count').catch(() => 0)
        if (n > 0) {
          const ok = await ask(
            `저장하지 않은 문서가 ${n}개 있습니다.\n변경 사항을 잃고 종료하시겠습니까?`,
            { title: '종료', kind: 'warning' },
          )
          if (!ok) return
        }
        invoke('quit_app').catch(() => {})
      })()
    },
  })
  await menu.start()

  // ── 이 창이 열 파일 결정 ─────────────────────────────────
  // (1) 새 창(New/Open/Finder warm)이면 URL 해시에 경로가 담겨 있다 → 로드.
  // (2) 해시가 없고 main(최초) 창이면, cold-start로 Finder가 넘긴 pending을 가져온다.
  //     RunEvent::Opened가 WebView mount 전에 fire되어 손실되는 경로를 Rust가 stash
  //     해뒀다가 webview_ready로 한 번에 넘겨준다. 여러 개면 첫 파일은 이 창에,
  //     나머지는 각각 새 창으로 연다. (호출 후부터 warm open은 open:file로 직접 전달)
  // (3) 둘 다 아니면 빈 새 문서.
  const hashRaw = location.hash.slice(1)
  const hashFile = hashRaw ? decodeURIComponent(hashRaw) : null
  if (hashFile) {
    await fileService.openPath(hashFile).catch(reportError('파일 열기'))
  } else if (win.label === 'main') {
    try {
      const pending: string[] = await invoke('webview_ready')
      if (pending.length > 0) {
        await fileService.openPath(pending[0]).catch(reportError('파일 열기'))
        for (const p of pending.slice(1)) openDocumentWindow(p).catch(reportError('새 창 열기'))
      }
    } catch (e) {
      console.error('webview_ready failed:', e)
    }
  }

  // ── 외부 변경 감지: 다른 앱에서 파일을 수정하고 Mallow로 돌아오면 동기화 ──
  // focus를 트리거로 디스크를 다시 읽어 비교한다. fs watcher 대신 focus를 쓰는 이유:
  //  (1) 사용자가 "돌아왔을 때" 갱신되길 기대하는 시나리오에 정확히 부합
  //  (2) 외부 앱이 저장 중인 partial write 상태를 잡을 위험이 없음
  win.onFocusChanged(({ payload: focused }) => {
    if (focused) fileService.syncFromDiskIfChanged().catch(reportError('파일 동기화'))
  })

  // ── 윈도우 닫기 (멀티 창) ────────────────────────────────
  // 항상 preventDefault한 뒤 closeThisWindow로 확인→destroy를 직접 처리한다.
  // (Tauri v2 macOS에서 콜백 내부 native close가 일관되지 않는 이슈 우회.)
  // 마지막 창이면 Rust RunEvent::WindowEvent::Destroyed에서 앱을 종료한다.
  win.onCloseRequested((event) => {
    event.preventDefault()
    void closeThisWindow()
  })
}

bootstrap().catch((e) => console.error('bootstrap failed:', e))
