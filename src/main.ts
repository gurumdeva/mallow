import './style.css'
import { ask } from '@tauri-apps/plugin-dialog'
import { getCurrentWindow } from '@tauri-apps/api/window'
import { WebviewWindow, getAllWebviewWindows } from '@tauri-apps/api/webviewWindow'
import { invoke } from '@tauri-apps/api/core'

import { Document } from './domain/Document'
import { UIState } from './domain/UIState'
import { EditorController } from './editor/EditorController'
import { StatsCalculator } from './analysis/StatsCalculator'
import { TocExtractor } from './analysis/TocExtractor'
import { RecentFilesStore } from './services/RecentFilesStore'
import { RecentMenuSync } from './services/RecentMenuSync'
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
  const recent = new RecentFilesStore()
  new RecentMenuSync(recent) // store 구독해서 메뉴 동기화
  new WindowTitleSync(doc)   // doc 구독해서 윈도우 타이틀 동기화
  const pdfExporter = new PdfExporter(doc)
  const fileService = new FileService(doc, editor, recent)

  // ── Views (stateless, 상태는 doc/ui에서만 read) ──────────
  new TitleBarView(doc, ui)
  new FilenamePopover(doc, ui)
  new InfoPopover(doc, ui, editor, stats, toc)
  new StylePopover(ui, editor)

  // ── Toast 알림 인프라 + 공용 에러 핸들러 ────────────────
  const toast = new ToastService()
  const reportError = (label: string) => (e: unknown) => {
    console.error(label, e)
    toast.error(`${label}: ${formatError(e)}`)
  }

  // ── Title bar의 PDF 아이콘 클릭 → export ─────────────────
  // 키보드 ⌘E는 MenuBridge가 처리하지만 버튼 클릭은 별도 wiring 필요.
  const btnPdf = document.getElementById('btn-pdf')
  btnPdf?.addEventListener('click', (e) => {
    e.stopPropagation()
    pdfExporter.export().catch(reportError('PDF 내보내기'))
  })

  // ── Wiring: editor 변경 → doc 수정 표시 ──────────────────
  editor.on('change', () => doc.markModified())

  const win = getCurrentWindow()

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
      const p = recent.list()[i]
      if (p) handleOpenPath(p)
    },
    onOpenFromOs: (p) => handleOpenPath(p),
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
  // 미저장이면 확인 후, 마지막 창이면 앱 종료(force_quit), 아니면 이 창만 닫는다.
  // Tauri v2 macOS에서 콜백 내부의 native close가 일관되지 않아, 항상 preventDefault
  // 한 뒤 Rust 커맨드(force_quit / close_document_window=window.destroy)로 명시 종료한다.
  win.onCloseRequested(async (event) => {
    event.preventDefault()
    if (doc.isModified) {
      const ok = await ask(
        '저장하지 않은 변경 사항이 있습니다.\n정말 닫으시겠습니까?',
        { title: '저장되지 않은 변경 사항', kind: 'warning' },
      )
      if (!ok) return // 사용자가 취소 → 창 유지
    }
    // 남은 창 수로 마지막 창 여부 판단 (현재 창 포함).
    const remaining = await getAllWebviewWindows().catch(() => [])
    if (remaining.length <= 1) {
      invoke('force_quit').catch(() => {})
    } else {
      invoke('close_document_window').catch(() => {})
    }
  })
}

bootstrap().catch((e) => console.error('bootstrap failed:', e))
