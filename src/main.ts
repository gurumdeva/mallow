import './style.css'
import { ask } from '@tauri-apps/plugin-dialog'
import { getCurrentWindow } from '@tauri-apps/api/window'
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

  // ── 초기 콘텐츠 로드 ────────────────────────────────────
  // 메뉴 리스너를 활성화하기 전에 editor를 초기화해, 사용자가 init 중에
  // 메뉴 항목(파일 열기 등)을 눌러도 half-initialized Crepe에 dispatch되는
  // race를 막는다. menu.start() 이후에 들어오는 이벤트는 항상 Created 상태의
  // editor를 만나도록 보장.
  await editor.initialize(DEFAULT_MARKDOWN)

  // ── Menu / OS file-open 이벤트 라우팅 ───────────────────
  const openFromOs = (p: string) => fileService.openPath(p).catch(reportError('파일 열기'))

  const menu = new MenuBridge({
    onNewFile: () => fileService.newFile().catch(reportError('새 파일')),
    onOpen: () => fileService.open().catch(reportError('파일 열기')),
    onSave: () => fileService.save().catch(reportError('저장')),
    onSaveAs: () => fileService.saveAs().catch(reportError('다른 이름으로 저장')),
    onExportPdf: () => pdfExporter.export().catch(reportError('PDF 내보내기')),
    onShowStats: () => ui.toggleInfoPopover(),
    onRecentOpen: (i) => fileService.openRecent(i).catch(reportError('최근 파일 열기')),
    onOpenFromOs: openFromOs,
  })
  await menu.start()

  // ── Cold-start 파일 인수 처리 ────────────────────────────
  // Finder에서 .md 파일을 더블클릭해 앱이 새로 뜨면 Rust의 RunEvent::Opened가
  // WebView mount 전에 fire 되어 'open:file' emit이 손실된다. Rust 쪽에 pending
  // 으로 쌓여 있던 경로를 listener 등록 직후에 한 번에 가져와 처리한다.
  // (이 호출 이후로 RunEvent::Opened는 stash 없이 바로 emit → 위 onOpenFromOs로 전달)
  try {
    const pending: string[] = await invoke('webview_ready')
    for (const p of pending) openFromOs(p)
  } catch (e) {
    console.error('webview_ready failed:', e)
  }

  // ── 윈도우 닫기 시 미저장 확인 ───────────────────────────
  // Tauri v2 macOS에서 onCloseRequested 핸들러가 등록되면 native close가
  // 자동으로 진행되지 않는 현상이 있어, 모든 경로에서 명시적으로 app.exit(0)을
  // 호출하는 Rust 커맨드(force_quit)를 invoke한다.
  const win = getCurrentWindow()
  win.onCloseRequested(async (event) => {
    if (doc.isModified) {
      event.preventDefault()
      const ok = await ask(
        '저장하지 않은 변경 사항이 있습니다.\n정말 닫으시겠습니까?',
        { title: '저장되지 않은 변경 사항', kind: 'warning' },
      )
      if (!ok) return // 사용자가 취소
    }
    invoke('force_quit').catch(() => {})
  })
}

bootstrap().catch((e) => console.error('bootstrap failed:', e))
