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
import { HtmlExporter } from './services/HtmlExporter'
import { FileService, RenameError, OpenError } from './services/FileService'
import { MenuBridge } from './services/MenuBridge'
import { TitleBarView } from './ui/TitleBarView'
import { FilenamePopover } from './ui/FilenamePopover'
import { InfoPopover } from './ui/InfoPopover'
import { StylePopover } from './ui/StylePopover'
import { FindReplace } from './ui/FindReplace'
import { StatusBar } from './ui/StatusBar'
import { ToastService, formatError } from './ui/ToastService'
import { setLocale, resolveLang, t } from './i18n'
import { welcomeDoc } from './welcome'

const DEFAULT_MARKDOWN = ''

async function bootstrap(): Promise<void> {
  const win = getCurrentWindow()

  // dragDropEnabled=false로 Tauri 네이티브 가로채기를 꺼 webview가 HTML5 drag-drop을 받는다
  // (crepe가 에디터 위 이미지 드롭을 처리). 단, 에디터 밖(타이틀바·여백)에 파일을 떨어뜨리면
  // webview 기본 동작이 그 파일로 navigate해 앱 화면이 깨지므로, window 레벨에서 기본 동작을
  // 막아 navigate를 차단한다. (에디터 내부 드롭은 ProseMirror가 먼저 처리하므로 영향 없음)
  window.addEventListener('dragover', (e) => e.preventDefault())
  window.addEventListener('drop', (e) => e.preventDefault())

  // ── 테마: OS 외관(라이트/다크)을 따라간다 (수동 선택 UI 없음) ──
  // index.html 인라인 스크립트가 1차 페인트 전에 data-theme를 이미 확정하지만,
  // 여기서 한 번 더 동기화해 (인라인 스크립트가 어떤 이유로 누락돼도) 일관성을 보장하고,
  // OS 외관이 "실행 중에" 바뀌면 즉시 반영되도록 리스너를 단다. (창마다 각자 수행)
  const applyTheme = (dark: boolean): void => {
    // data-theme뿐 아니라 index.html 인라인 스크립트가 1차 페인트 전에 세팅한
    // html 배경·color-scheme도 함께 갱신한다. 안 그러면 실행 중 OS 외관이 바뀔 때
    // (라이브 전환) 인라인 값이 그대로 남아 스크롤바 등 native 컨트롤 색이 어긋난다.
    const root = document.documentElement
    root.setAttribute('data-theme', dark ? 'dark' : 'light')
    root.style.background = dark ? '#1c1c1e' : '#ffffff'
    root.style.colorScheme = dark ? 'dark' : 'light'
  }
  try {
    const mq = window.matchMedia('(prefers-color-scheme: dark)')
    applyTheme(mq.matches)
    mq.addEventListener('change', (e) => applyTheme(e.matches))
  } catch {
    /* matchMedia 미지원 → index.html의 다크 폴백을 그대로 둔다 */
  }

  // 새 창(doc-*)의 다크 webview 처리를 "가장 먼저" 호출한다. main 창은 Rust setup()이
  // 처리하지만 doc 창은 이 invoke로만 처리된다. locale IPC 등 다른 await 뒤로 밀리면
  // 첫 페인트에서 흰 flash가 1프레임 보일 수 있어, locale 판정보다 앞에 둔다(fire-and-forget).
  if (win.label !== 'main') invoke('apply_dark_webview').catch(() => {})

  // ── i18n: 기기 언어 결정 (Document·뷰 생성 전에) ──────────
  // Rust(sys-locale)가 OS 언어를 권위 있게 판정해 'ko'|'ja'|'en'을 돌려준다.
  // (macOS 비현지화 앱에서 navigator.language가 dev 지역으로 고정되는 함정을 피한다.)
  // 실패 시 navigator.language로 폴백. Document·뷰 생성 전에 적용해야 모든 문자열이
  // 한 언어로 일관되게 만들어진다(생성자 안에서 t()를 읽는 곳이 있으므로).
  const rawLocale = await invoke<string>('app_locale').catch(() => navigator.language)
  const lang = resolveLang(rawLocale)
  setLocale(lang)
  document.documentElement.lang = lang
  // index.html의 정적 버튼 tooltip을 기기 언어로 채운다(HTML엔 텍스트를 두지 않음).
  // title(마우스 툴팁)과 aria-label(보조기술용 접근 이름)을 같은 문구로 함께 설정한다(item 13).
  const labelButton = (id: string, text: string): void => {
    const el = document.getElementById(id)
    el?.setAttribute('title', text)
    el?.setAttribute('aria-label', text)
  }
  labelButton('btn-style', t('titlebar.styleTip'))
  labelButton('btn-pdf', t('titlebar.exportPdfTip'))
  labelButton('btn-info', t('titlebar.infoTip'))
  // 이름 변경 입력란은 보이는 라벨이 없으므로 접근 이름을 지역화해 부여한다.
  document.getElementById('filename-input')?.setAttribute('aria-label', t('titlebar.renameTip'))

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
  const htmlExporter = new HtmlExporter(doc)
  const fileService = new FileService(doc, editor, recent)

  // ── Toast 알림 인프라 + 공용 에러 핸들러 ────────────────
  // (View보다 먼저 정의: FilenamePopover의 rename 콜백에서 참조하기 때문)
  const toast = new ToastService()
  const reportError = (label: string) => (e: unknown) => {
    console.error(label, e)
    toast.error(`${label}: ${formatError(e)}`)
  }

  // 파일 열기 실패 처리: 읽기 실패(OpenError)는 보통 삭제/이동된 파일이라 이미 최근
  // 목록에서 제거된 상태 → 일반 오류 대신 "더 이상 존재하지 않아 최근 목록에서 제거함"을
  // 안내한다. 그 밖의 오류는 일반 파일 열기 오류 토스트로 보고한다.
  const reportOpenError = (e: unknown): void => {
    if (e instanceof OpenError) {
      console.error('openPath failed:', e.cause)
      toast.info(t('toast.recentRemoved'))
    } else {
      reportError(t('error.openFile'))(e)
    }
  }

  // 내보내기(PDF/HTML) 공용 래퍼: (1) 빈 문서면 다이얼로그를 열지 않고 안내(빈 파일 생성 방지),
  // (2) 저장 성공 시 성공 토스트(이전엔 조용히 끝나 피드백이 없었다). exporter는 저장 경로|null 반환.
  const runExport = (
    exporter: { export(): Promise<string | null> },
    errorLabel: string,
  ): void => {
    if (editor.getMarkdown().trim() === '') {
      toast.info(t('toast.nothingToExport'))
      return
    }
    exporter
      .export()
      .then((savedPath) => {
        if (savedPath) {
          const name = savedPath.split(/[/\\]/).pop() || savedPath
          toast.info(t('toast.exported', { name }))
        }
      })
      .catch(reportError(errorLabel))
  }

  // ── Views (stateless, 상태는 doc/ui에서만 read) ──────────
  new TitleBarView(doc, ui)
  // 파일명 확정: 저장된 문서면 디스크 파일까지 rename, 새 문서면 표시명만 (FileService.applyRename).
  // rename 실패는 사유별로 안내한다: 잘못된 이름 / 같은 이름의 파일이 이미 있음 / 기타 오류.
  new FilenamePopover(doc, ui, (name) =>
    fileService.applyRename(name).catch((e) => {
      const code = e instanceof RenameError ? e.code : null
      if (code === 'exists') toast.error(t('error.renameExists'))
      else if (code === 'invalid') toast.error(t('error.renameInvalid'))
      else reportError(t('error.rename'))(e)
    }),
  )
  new InfoPopover(doc, ui, editor, stats, toc)
  new StylePopover(ui, editor)

  // ── 찾기/바꾸기 ──────────────────────────────────────────
  // ⌘F는 네이티브 Edit 메뉴의 "찾기" 항목(accelerator)으로 들어온다(menu:find → onFind).
  // webview keydown으로 ⌘F를 잡으면 macOS responder chain이 먼저 소비해 도달하지 않는다.
  const findReplace = new FindReplace(editor)

  // ── 하단 상태바: 단어 수 / 읽기 시간 (빈 문서면 숨김) ──────
  new StatusBar(doc, editor, stats)

  // ── Title bar의 PDF 아이콘 클릭 → export ─────────────────
  // 키보드 ⌘E는 MenuBridge가 처리하지만 버튼 클릭은 별도 wiring 필요.
  const btnPdf = document.getElementById('btn-pdf')
  btnPdf?.addEventListener('click', (e) => {
    e.stopPropagation()
    runExport(pdfExporter, t('error.exportPdf'))
  })

  // ── Wiring: editor 변경 → doc 수정 표시 ──────────────────
  editor.on('change', () => doc.markModified())
  // 이미지 붙여넣기/드롭/업로드 실패 시 사유에 맞는 토스트를 띄운다.
  // (용량 초과 vs 읽기·삽입 실패를 구분; 여러 파일이어도 사유당 1회만 발행됨)
  editor.on('imageerror', (reason) => {
    toast.error(reason === 'too-large' ? t('toast.imageTooLarge') : t('toast.imageError'))
  })

  // 이 창의 미저장 여부를 Rust에 보고한다(⌘Q 원자적 종료 판단용).
  // doc 'changed'는 자주 불리므로 isModified가 "실제로 바뀔 때"만 IPC를 보낸다.
  let reportedDirty = false
  doc.on('changed', () => {
    if (doc.isModified !== reportedDirty) {
      reportedDirty = doc.isModified
      invoke('set_window_dirty', { dirty: reportedDirty }).catch(() => {})
    }
  })

  // ── 자동 저장 ────────────────────────────────────────────
  // 이미 저장된 문서(filePath 있음)는 편집이 잠시 멈추면 디스크에 자동 반영한다.
  // 제목 없는 새 문서는 대상이 아니다(저장 다이얼로그를 띄우지 않기 위해).
  // save()의 isSaving 가드와 외부 변경 sync의 baseline 가드가 동시 쓰기/읽기를 안전하게 처리한다.
  let autosaveTimer: ReturnType<typeof setTimeout> | null = null
  doc.on('changed', () => {
    if (autosaveTimer) {
      clearTimeout(autosaveTimer)
      autosaveTimer = null
    }
    if (doc.isModified && doc.filePath) {
      autosaveTimer = setTimeout(() => {
        autosaveTimer = null
        fileService.save().catch(reportError(t('error.save')))
      }, 1500)
    }
  })

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
      title: t('doc.untitled'),
      width: 980,
      height: 760,
      titleBarStyle: 'overlay',
      hiddenTitle: true,
      // Tauri 네이티브 파일-드롭 가로채기를 꺼서 webview가 HTML5 drag-drop을 받게 한다
      // (crepe가 에디터 위 이미지 드롭을 처리). main 창은 tauri.conf.json에서 동일 설정.
      dragDropEnabled: false,
      backgroundColor: [28, 28, 30],
      ...(position ?? {}),
    })
    void w.once('tauri://error', (e) => reportError(t('error.openWindow'))(e.payload))
  }

  // 파일 열기: 현재 창이 "깨끗한 새 문서"면 그 창을 재사용(in-place), 아니면 새 창.
  // 덕분에 앱을 갓 켠 빈 창에서 열면 빈 창이 남지 않고, 작업 중인 창은 보존된다.
  const handleOpenPath = (filePath: string): void => {
    if (doc.isPristine) {
      fileService.openPath(filePath).catch(reportOpenError)
    } else {
      openDocumentWindow(filePath).catch(reportError(t('error.openWindow')))
    }
  }

  // 현재 창 닫기: 미저장이면 확인 후 close_document_window로 이 창만 destroy한다.
  // 마지막 창이면 Rust RunEvent가 webview_windows 빈 것을 보고 앱을 종료한다.
  // 창 닫기 버튼/⌘W(onCloseRequested)와 ⌘Q(menu:quit) 양쪽에서 공용으로 쓴다.
  const closeThisWindow = async (): Promise<void> => {
    if (doc.isModified) {
      // 멀티 창에서 여러 확인창이 떠도 구분되도록 파일명을 함께 표시.
      const ok = await ask(
        t('dialog.unsavedClose.body', { name: doc.filename }),
        { title: t('dialog.unsavedClose.title'), kind: 'warning' },
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
  // ⌘Q 재진입 가드: 종료 확인창이 떠 있는 동안 ⌘Q가 다시 들어와 다이얼로그가 겹치는 것을 막는다.
  let quitting = false
  const menu = new MenuBridge({
    onNewFile: () => openDocumentWindow(null).catch(reportError(t('error.openWindow'))),
    onOpen: () =>
      fileService
        .pickOpenPath()
        .then((p) => {
          if (p) handleOpenPath(p)
        })
        .catch(reportError(t('error.openFile'))),
    onSave: () => fileService.save().catch(reportError(t('error.save'))),
    onSaveAs: () => fileService.saveAs().catch(reportError(t('error.saveAs'))),
    onExportPdf: () => runExport(pdfExporter, t('error.exportPdf')),
    onExportHtml: () => runExport(htmlExporter, t('error.exportHtml')),
    onShowStats: () => ui.toggleInfoPopover(),
    onFind: () => findReplace.toggle(),
    // Open Recent 클릭은 Rust가 클릭 순간 실제 경로를 해석해 open:file로 보낸다
    // (인덱스 race 방지). OS 파일 열기와 동일 경로(onOpenFromOs)로 처리된다.
    onOpenFromOs: (p) => handleOpenPath(p),
    // ⌘Q: 포커스 창이 코디네이터. 전체 미저장 문서 수를 Rust에서 조회해 통합 확인 1회 →
    // 종료(quit_app=app.exit) 또는 취소. 부분 종료(일부 창만 닫힘)가 발생하지 않는다.
    onQuit: () => {
      if (quitting) return
      quitting = true
      void (async () => {
        const n = await invoke<number>('dirty_window_count').catch(() => 0)
        if (n > 0) {
          // 영어 단/복수 구분(item 14): 1건이면 단수("1 document has…"), 그 외 복수형.
          // 한국어/일본어는 복수 굴절이 없어 두 키가 같은 단일 문구를 가리킨다.
          const bodyKey = n === 1 ? 'dialog.unsavedQuit.bodyOne' : 'dialog.unsavedQuit.bodyMany'
          const ok = await ask(
            t(bodyKey, { count: n }),
            { title: t('dialog.unsavedQuit.title'), kind: 'warning' },
          )
          if (!ok) {
            quitting = false // 취소 → 다시 ⌘Q 할 수 있도록 해제
            return
          }
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
    await fileService.openPath(hashFile).catch(reportOpenError)
  } else if (win.label === 'main') {
    try {
      const pending: string[] = await invoke('webview_ready')
      if (pending.length > 0) {
        await fileService.openPath(pending[0]).catch(reportOpenError)
        for (const p of pending.slice(1)) openDocumentWindow(p).catch(reportError(t('error.openWindow')))
      } else if (!localStorage.getItem('mallow.welcomed')) {
        // 첫 실행 + 열 파일 없음 → 환영 문서 1회 표시. load()가 change 이벤트를 억제하므로
        // 문서는 미수정(pristine) 상태로 남아, 닫을 때 저장 확인이 뜨지 않고 파일 열기 시 재사용된다.
        localStorage.setItem('mallow.welcomed', '1')
        await editor.load(welcomeDoc(lang)).catch(() => {})
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
    if (focused) fileService.syncFromDiskIfChanged().catch(reportError(t('error.syncFile')))
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
