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

  // ── Title bar의 PDF 아이콘 클릭 → export ─────────────────
  // 키보드 ⌘E는 MenuBridge가 처리하지만 버튼 클릭은 별도 wiring 필요.
  const btnPdf = document.getElementById('btn-pdf')
  btnPdf?.addEventListener('click', (e) => {
    e.stopPropagation()
    pdfExporter.export().catch(console.error)
  })

  // ── Wiring: editor 변경 → doc 수정 표시 ──────────────────
  editor.on('change', () => doc.markModified())

  // ── Menu / OS file-open 이벤트 라우팅 ───────────────────
  const menu = new MenuBridge({
    onNewFile: () => fileService.newFile().catch(console.error),
    onOpen: () => fileService.open().catch(console.error),
    onSave: () => fileService.save().catch(console.error),
    onSaveAs: () => fileService.saveAs().catch(console.error),
    onExportPdf: () => pdfExporter.export().catch(console.error),
    onShowStats: () => ui.toggleInfoPopover(),
    onRecentOpen: (i) => fileService.openRecent(i).catch(console.error),
    onOpenFromOs: (p) => fileService.openPath(p).catch(console.error),
  })
  await menu.start()

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

  // ── 초기 콘텐츠 로드 ────────────────────────────────────
  await editor.initialize(DEFAULT_MARKDOWN)
}

bootstrap().catch((e) => console.error('bootstrap failed:', e))
