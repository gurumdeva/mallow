import { save as saveDialog } from '@tauri-apps/plugin-dialog'
import { writeTextFile } from '@tauri-apps/plugin-fs'
import { Document } from '../domain/Document'
import { t } from '../i18n'

/**
 * 현재 본문(.ProseMirror)을 렌더된 그대로 가져와 독립 실행형 HTML 문서로 내보낸다.
 *
 * crepe는 리스트/코드블록/이미지 등을 인터랙티브 web-component(CodeMirror, Vue 컴포넌트)로
 * 렌더하므로, 살아있는 DOM을 그대로 임베드하면 에디터 전용 스캐폴딩(인라인 SVG 불릿,
 * .cm-* 편집기, 언어 피커, 리사이즈 핸들, Find 하이라이트 등)이 결과물에 새어 나간다.
 * 그래서 클론한 DOM을 `normalizeExportHtml`로 정규화해 의미론적 HTML(<ul>/<ol>/<li>,
 * <pre><code>, <img>)만 남긴 뒤 `buildHtmlDocument`로 감싼다.
 *
 * (PdfExporter와 동일하게 saveDialog로 사용자가 경로를 고르고 writeTextFile로 저장한다.)
 */
export class HtmlExporter {
  /** 진행 중 중복 호출(빠른 연타, 메뉴+단축키 동시) 무시. */
  private isExporting = false

  constructor(private readonly doc: Document) {}

  /**
   * 본문을 HTML 파일로 저장한다.
   *
   * @returns 저장에 성공하면 저장된 파일 경로(string). 사용자가 저장 대화상자를
   *   취소했거나(또는 본문/중복 호출로 진행 불가) 아무것도 쓰지 않았으면 `null`.
   *   호출자는 이 반환값으로 성공 토스트를 띄울 수 있다(여기서는 토스트를 직접 띄우지 않는다).
   *   파일 쓰기 실패는 예외로 던져 호출자의 `.catch`가 보고하게 한다.
   */
  async export(): Promise<string | null> {
    // 진행 중이면 조용히 무시(반환값으로도 "안 함"을 알 수 있게 null).
    if (this.isExporting) return null
    const source = document.querySelector('.ProseMirror') as HTMLElement | null
    if (!source) return null

    const base = this.doc.filename.replace(/\.md$/i, '') || t('doc.fallbackName')
    // 저장된 문서면 같은 폴더의 .html을 기본값으로(예측 가능), 아니면 이름만.
    const defaultPath = this.doc.filePath
      ? this.doc.filePath.replace(/\.md$/i, '.html')
      : `${base}.html`

    // 현재 앱 테마(OS 외관 추종)를 읽어 결과 문서의 색을 맞춘다.
    const dark = document.documentElement.dataset.theme === 'dark'

    this.isExporting = true
    try {
      const selected = await saveDialog({
        defaultPath,
        filters: [{ name: 'HTML', extensions: ['html'] }],
      })
      // 사용자가 취소하면 throw 없이 null 반환(호출자가 토스트를 건너뛰도록).
      if (!selected) return null
      const body = normalizeExportHtml(source)
      // 쓰기 실패는 일부러 던진다(호출자 .catch가 보고).
      await writeTextFile(selected, buildHtmlDocument(base, body, dark))
      return selected
    } finally {
      this.isExporting = false
    }
  }
}

/**
 * 살아있는 .ProseMirror 엘리먼트(또는 그 클론)를 받아, 에디터 전용 스캐폴딩을 벗겨낸
 * 깨끗한 의미론적 HTML 문자열(innerHTML)을 돌려주는 순수 함수.
 *
 * 원본은 건드리지 않도록 항상 깊은 클론을 만들어 그 위에서 작업한다.
 * Tauri/에디터 런타임에 의존하지 않으므로 jsdom에서 단위 테스트할 수 있다.
 */
export function normalizeExportHtml(sourceEl: HTMLElement): string {
  // 원본 보호: 깊은 클론 위에서만 변형한다.
  const root = sourceEl.cloneNode(true) as HTMLElement

  // 순서 주의:
  // 1) 코드블록을 먼저 정규화한다. CodeMirror 스캐폴딩 안에는 .search-match류
  //    클래스나 다른 chrome이 끼어들 여지가 있어 통째로 교체하는 편이 안전하다.
  normalizeCodeBlocks(root)
  // 2) 표 블록 → 의미론적 <table>. crepe 표는 드래그 핸들/행·열 추가 버튼/SVG 아이콘이
  //    잔뜩 달린 .milkdown-table-block로 렌더되어, 손대지 않으면 그 chrome이 통째로 새어 나간다.
  //    (리스트 정규화보다 먼저 — 셀 안 리스트는 추출 후 normalizeListItems가 처리한다.)
  normalizeTableBlocks(root)
  // 3) 이미지 블록 → <img>
  normalizeImageBlocks(root)
  // 4) 리스트 wrapper chrome 제거 → 의미론적 <li>
  normalizeListItems(root)
  // 5) 수식: 편집용 KaTeX 렌더(CSS 없이는 깨져 보이고 MathML+HTML이 중복 노출됨)를
  //    data-value의 LaTeX 원문으로 치환해 의존성 없이 깔끔하게 남긴다.
  normalizeMath(root)
  // 6) 편집 전용 위젯/장식(빈 .ProseMirror-widget, gap cursor, hardbreak 등) 정리.
  stripEditorScaffolding(root)
  // 7) 남아있는 Find 하이라이트 span 언랩(텍스트는 보존).
  unwrapSearchMatches(root)
  // 8) XSS 방어: 내보낸 .html은 브라우저에서 열리거나 공유될 수 있으므로,
  //    신뢰할 수 없는 문서에서 온 링크 href와 이미지 src의 스킴을 화이트리스트로 검사한다.
  //    (이미지 블록 정규화 뒤에 돌려서 거기서 만든 <img>의 src까지 함께 검사한다.)
  sanitizeLinkHrefs(root)
  sanitizeImageSrcs(root)

  return root.innerHTML
}

/**
 * crepe 리스트 아이템 정규화.
 *
 * 실제 클론 구조(=node-view dom):
 *   <ul data-spread="…">            ← <ul>/<ol>은 진짜 엘리먼트
 *     <div class="milkdown-list-item-block">   ← <li> 자리를 대체하는 wrapper
 *       <li class="list-item">
 *         <div class="label-wrapper"><span class="milkdown-icon …"><svg/></span></div>  ← 인라인 SVG 불릿
 *         <div class="children">
 *           <div class="content-dom" data-content-dom="true"><p>…</p></div>  ← 진짜 내용
 *         </div>
 *       </li>
 *     </div>
 *   </ul>
 *
 * 목표: <li> 안에서 .label-wrapper(불릿 SVG)와 wrapper들(.children/.content-dom)을
 * 걷어내고 내용만 남긴 뒤, .milkdown-list-item-block div를 <li>로 치환해
 * <ul>/<ol> > <li> > 내용 의 깔끔한 트리로 만든다. (불릿은 CSS list-style이 그린다.)
 */
function normalizeListItems(root: HTMLElement): void {
  // .milkdown-list-item-block 은 중첩 리스트에서도 안쪽부터 처리하면 일관되지만,
  // 각 블록을 독립적으로 평탄화하므로 순서에 민감하지 않다.
  const blocks = Array.from(root.querySelectorAll('.milkdown-list-item-block'))
  for (const block of blocks) {
    // 내부의 <li class="list-item">를 찾는다(없으면 block 자체를 내용 컨테이너로 취급).
    const innerLi = block.querySelector('li')
    const li = block.ownerDocument.createElement('li')

    if (innerLi) {
      // 체크리스트면 결과 HTML에도 표식을 남겨 CSS가 구분할 수 있게 한다.
      const labelSpan = innerLi.querySelector('.label-wrapper .label')
      if (labelSpan) {
        if (labelSpan.classList.contains('checked')) {
          li.setAttribute('data-checked', 'true')
        } else if (labelSpan.classList.contains('unchecked')) {
          li.setAttribute('data-checked', 'false')
        }
      }
      // 불릿/체크박스 chrome 제거.
      innerLi.querySelectorAll('.label-wrapper').forEach((el) => el.remove())

      // 내용을 옮긴다: 이 아이템의 "직속" .children > .content-dom 안의 자식들만 <li>로
      // 끌어올린다. querySelectorAll('.content-dom')는 재귀라 중첩 리스트 아이템의 content-dom까지
      // 끌어올려, 중첩 아이템이 빈 <li>가 되고 그 텍스트가 부모로 올라붙는 버그가 있었다.
      // :scope > .children > .content-dom 으로 자기 것만 고른다(중첩 <ul>은 이 content-dom 안에
      // 그대로 남아, 다음 루프에서 자기 차례에 정규화된다).
      const contentHosts = innerLi.querySelectorAll(':scope > .children > .content-dom')
      if (contentHosts.length > 0) {
        contentHosts.forEach((host) => {
          while (host.firstChild) li.appendChild(host.firstChild)
        })
      } else {
        // content-dom이 없으면(이론상) .children 또는 li의 남은 자식을 그대로 옮긴다.
        const children = innerLi.querySelector('.children')
        const moveFrom = children ?? innerLi
        while (moveFrom.firstChild) li.appendChild(moveFrom.firstChild)
      }
    } else {
      // <li>가 없으면 block의 자식을 그대로 옮긴다(방어적).
      while (block.firstChild) li.appendChild(block.firstChild)
    }

    block.replaceWith(li)
  }

  // 단일 단락만 담은 <li>는 <p> 래퍼를 벗겨 더 자연스러운 리스트로 만든다.
  // (crepe 리스트 아이템은 항상 paragraph로 감싸지므로 <li><p>text</p></li> 형태가 됨)
  unwrapSoleParagraphInListItems(root)
}

/** <li>가 단 하나의 <p>만 가지면 그 <p>를 풀어 <li> 직속 텍스트로 만든다. */
function unwrapSoleParagraphInListItems(root: HTMLElement): void {
  root.querySelectorAll('li').forEach((li) => {
    // 자식 엘리먼트가 <p> 하나뿐이고, 텍스트 노드(공백 제외)가 없을 때만.
    const elementChildren = Array.from(li.children)
    const hasMeaningfulText = Array.from(li.childNodes).some(
      (n) => n.nodeType === Node.TEXT_NODE && (n.textContent ?? '').trim() !== '',
    )
    if (elementChildren.length === 1 && elementChildren[0].tagName === 'P' && !hasMeaningfulText) {
      const p = elementChildren[0]
      while (p.firstChild) li.insertBefore(p.firstChild, p)
      p.remove()
    }
  })
}

/**
 * crepe 코드블록(CodeMirror) 정규화.
 *
 * 실제 클론 구조는 두 가지 상태가 있다:
 *  (a) 미초기화(placeholder): <div class="milkdown-code-block">
 *        <pre class="milkdown-code-block-placeholder"><code>{코드 텍스트}</code></pre>
 *  (b) CodeMirror 초기화됨: <div class="milkdown-code-block">
 *        <div class="tools"> … <div class="language-button">js</div> … 언어 피커/복사 버튼 …
 *        <div class="codemirror-host"><div class="cm-editor"> … <div class="cm-gutters">줄번호</div>
 *           <div class="cm-content"><div class="cm-line">코드 한 줄</div>…</div> … </div></div>
 *        <div class="preview-panel">…</div>
 *
 * 목표: 어느 상태든 <pre><code class="language-xxx">{코드}</code></pre> 하나로 치환하고
 * 편집기/피커/줄번호/프리뷰 chrome을 전부 버린다. 언어는 가능하면 보존한다.
 */
function normalizeCodeBlocks(root: HTMLElement): void {
  const blocks = Array.from(root.querySelectorAll('.milkdown-code-block'))
  for (const block of blocks) {
    const docu = block.ownerDocument
    const code = extractCodeText(block)
    const language = extractCodeLanguage(block)

    const pre = docu.createElement('pre')
    const codeEl = docu.createElement('code')
    if (language) codeEl.className = `language-${language}`
    // textContent로 넣어 HTML 이스케이프를 보장(스캐폴딩 마크업이 새어들지 않음).
    codeEl.textContent = code
    pre.appendChild(codeEl)
    block.replaceWith(pre)
  }
}

/** 코드블록 클론에서 코드 텍스트를 뽑아낸다(초기화/미초기화 상태 모두 대응). */
function extractCodeText(block: Element): string {
  // (a) placeholder가 있으면 그 <code>의 textContent가 가장 깨끗하다.
  const placeholder = block.querySelector('.milkdown-code-block-placeholder code')
  if (placeholder) return placeholder.textContent ?? ''

  // (b) CodeMirror가 그린 .cm-content > .cm-line 들을 줄바꿈으로 잇는다.
  const content = block.querySelector('.cm-content')
  if (content) {
    const lines = Array.from(content.querySelectorAll('.cm-line'))
    if (lines.length > 0) {
      // 빈 줄(.cm-line)은 textContent가 ''이거나 BR/zero-width일 수 있어 그대로 둔다.
      return lines.map((l) => l.textContent ?? '').join('\n')
    }
    return content.textContent ?? ''
  }

  // 최후 수단: 블록 전체 텍스트(피커/툴 텍스트가 섞일 수 있으나 마지막 fallback).
  return block.textContent ?? ''
}

/** 코드블록 클론에서 언어 이름을 뽑아낸다(없으면 null). */
function extractCodeLanguage(block: Element): string | null {
  // 1) node-view가 wrapper에 남긴 data-language(있으면 가장 신뢰).
  const el = block as HTMLElement
  const dataLang = el.dataset?.language
  if (dataLang && dataLang.trim()) return normalizeLangToken(dataLang)

  // 2) 언어 피커 버튼 텍스트. "Text"(=언어 미지정 placeholder)는 무시한다.
  const button = block.querySelector('.language-button')
  if (button) {
    // 버튼 안의 아이콘(.expand-icon 등)을 제외한 텍스트만 취하기 위해 직속 텍스트를 본다.
    const raw = directTextOf(button) || button.textContent || ''
    const token = raw.trim()
    if (token && token.toLowerCase() !== 'text') return normalizeLangToken(token)
  }
  return null
}

/** 엘리먼트의 직속 텍스트 노드만 모은다(자식 엘리먼트 텍스트 제외). */
function directTextOf(el: Element): string {
  let out = ''
  el.childNodes.forEach((n) => {
    if (n.nodeType === Node.TEXT_NODE) out += n.textContent ?? ''
  })
  return out
}

/** 언어 토큰을 class에 안전한 소문자 슬러그로(공백/특수문자 → 하이픈). */
function normalizeLangToken(s: string): string {
  return s
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
}

/**
 * crepe 이미지 블록 정규화.
 *
 * 실제 클론 구조:
 *   <div class="milkdown-image-block">
 *     <div class="image-wrapper">
 *       <div class="operation"><div class="operation-item">…버튼…</div></div>
 *       <img src="data:image/png;base64,…" alt="…">   ← 진짜 이미지(이미 data-URI src 보유)
 *       <div class="image-resize-handle"></div>
 *     </div>
 *     <input class="caption-input" …>   ← 선택적 캡션 입력
 *   </div>
 *
 * 목표: 내부 <img>만 꺼내 <img src alt>로 남기고(가능하면 캡션을 alt로 보강) wrapper chrome을 버린다.
 */
function normalizeImageBlocks(root: HTMLElement): void {
  const blocks = Array.from(root.querySelectorAll('.milkdown-image-block'))
  for (const block of blocks) {
    const docu = block.ownerDocument
    const srcImg = block.querySelector('img') as HTMLImageElement | null
    if (!srcImg) {
      // 이미지가 아직 없으면(빈 placeholder) 블록을 통째로 제거.
      block.remove()
      continue
    }
    const img = docu.createElement('img')
    const src = srcImg.getAttribute('src')
    if (src) img.setAttribute('src', src) // data-URI 보존
    // alt 우선순위: 기존 alt → 캡션 input 값.
    let alt = srcImg.getAttribute('alt') || ''
    if (!alt) {
      const caption = block.querySelector('.caption-input') as HTMLInputElement | null
      if (caption) alt = caption.getAttribute('value') || caption.value || ''
    }
    img.setAttribute('alt', alt)
    // title이 의미를 담고 있으면 보존.
    const title = srcImg.getAttribute('title')
    if (title) img.setAttribute('title', title)
    block.replaceWith(img)
  }
}

/**
 * crepe 표 블록 정규화.
 *
 * 실제 클론 구조(node-view):
 *   <div class="milkdown-table-block">
 *     <div>  ← 핸들 컨테이너
 *       <div data-role="col-drag-handle" class="handle cell-handle">…SVG + button-group(행/열 추가·삭제)…</div>
 *       <div data-role="row-drag-handle" class="handle cell-handle">…</div>
 *       <div class="table-wrapper">
 *         <div class="drag-preview"><table><tbody></tbody></table></div>   ← 빈 미리보기 표(버려야 함)
 *         <div data-role="x-line-drag-handle" class="handle line-handle"><button class="add-button">+…</button></div>
 *         <div data-role="y-line-drag-handle" …>+…</div>
 *         <table class="children">
 *           <tbody data-content-dom="true" class="content-dom">  ← 진짜 표 내용
 *             <tr data-is-header="true"><th style="text-align:left"><p>…</p></th>…</tr>
 *             <tr><td style="text-align:left"><p>…</p></td>…</tr>
 *           </tbody>
 *         </table>
 *       </div>
 *     </div>
 *   </div>
 *
 * 목표: 진짜 내용 tbody(data-content-dom)만 꺼내, 셀 정렬(text-align)을 보존하면서
 * 깔끔한 <table><tbody><tr><th|td>…</tr></tbody></table>로 재구성한다. 핸들/버튼/미리보기/SVG는
 * 전부 버린다. (drag-preview의 빈 표를 잘못 고르지 않도록 content-dom tbody를 기준으로 찾는다.)
 */
function normalizeTableBlocks(root: HTMLElement): void {
  const blocks = Array.from(root.querySelectorAll('.milkdown-table-block'))
  for (const block of blocks) {
    const docu = block.ownerDocument
    // 진짜 내용 tbody: data-content-dom 표식이 있는 것(빈 drag-preview 표가 아니라).
    const contentTbody = block.querySelector('tbody[data-content-dom], tbody.content-dom')
    if (!contentTbody) {
      block.remove() // 내용을 못 찾으면(이론상) 블록 통째로 버린다.
      continue
    }
    const table = docu.createElement('table')
    const tbody = docu.createElement('tbody')
    contentTbody.querySelectorAll(':scope > tr').forEach((tr) => {
      const newTr = docu.createElement('tr')
      tr.querySelectorAll(':scope > th, :scope > td').forEach((cell) => {
        const tag = cell.tagName.toLowerCase() === 'th' ? 'th' : 'td'
        const newCell = docu.createElement(tag)
        const align = (cell as HTMLElement).style?.textAlign
        if (align) newCell.style.textAlign = align
        // 병합 셀 속성 보존(GFM 표엔 없지만, 붙여넣기 등으로 들어오면 격자가 어긋나지 않게).
        const colspan = cell.getAttribute('colspan')
        const rowspan = cell.getAttribute('rowspan')
        if (colspan) newCell.setAttribute('colspan', colspan)
        if (rowspan) newCell.setAttribute('rowspan', rowspan)
        // 셀 내용을 "그대로" 옮긴다. crepe 표 셀은 자기 content-dom 없이 블록(<p> 등)을 직속으로
        // 가진다. cell.querySelector('.content-dom')는 "하위" content-dom(셀 안 중첩 리스트/표의 것)까지
        // 잡아, 그 안쪽만 남기고 나머지 셀 내용을 통째로 버리는 데이터 손실 버그가 있었다. 셀 자체를
        // host로 쓰면, 중첩 리스트는 뒤의 normalizeListItems가, 중첩 표는 같은 루프의 다음 차례가
        // (querySelectorAll가 문서 순서로 잡아둔다) 각각 정규화한다.
        while (cell.firstChild) newCell.appendChild(cell.firstChild)
        newTr.appendChild(newCell)
      })
      tbody.appendChild(newTr)
    })
    table.appendChild(tbody)
    block.replaceWith(table)
  }
  // 셀 안 단독 <p>는 풀어 <th|td> 직속 텍스트로(리스트 아이템과 동일한 처리).
  unwrapSoleParagraphInCells(root)
}

/** <td>/<th>가 단 하나의 <p>만 가지면 그 <p>를 풀어 셀 직속 텍스트로 만든다. */
function unwrapSoleParagraphInCells(root: HTMLElement): void {
  root.querySelectorAll('td, th').forEach((cell) => {
    const elementChildren = Array.from(cell.children)
    const hasMeaningfulText = Array.from(cell.childNodes).some(
      (n) => n.nodeType === Node.TEXT_NODE && (n.textContent ?? '').trim() !== '',
    )
    if (elementChildren.length === 1 && elementChildren[0].tagName === 'P' && !hasMeaningfulText) {
      const p = elementChildren[0]
      while (p.firstChild) cell.insertBefore(p.firstChild, p)
      p.remove()
    }
  })
}

/**
 * 수식 정규화. crepe Latex 기능은 수식을 편집용 KaTeX로 렌더한다:
 *   인라인: <span data-type="math_inline" data-value="E = mc^2"><span class="katex">…MathML+HTML…</span></span>
 *   블록:   <div data-type="math_block" data-value="…">…</div>
 * 내보낸 .html에는 KaTeX CSS가 없어, 그대로 두면 MathML과 HTML이 둘 다 보이며 깨져 나온다.
 * 그래서 data-value의 LaTeX 원문만 남긴다(인라인 → <code>, 블록 → <pre><code>). 의존성 없이 깔끔하고
 * 의미가 보존된다. (KaTeX를 그대로 렌더하려면 CSS+폰트 임베드가 필요 — 추후 옵션.)
 */
function normalizeMath(root: HTMLElement): void {
  root.querySelectorAll('[data-type="math_inline"]').forEach((el) => {
    const latex = el.getAttribute('data-value') ?? el.textContent ?? ''
    const code = el.ownerDocument.createElement('code')
    code.textContent = latex
    el.replaceWith(code)
  })
  root.querySelectorAll('[data-type="math_block"]').forEach((el) => {
    const latex = el.getAttribute('data-value') ?? el.textContent ?? ''
    const pre = el.ownerDocument.createElement('pre')
    const code = el.ownerDocument.createElement('code')
    code.textContent = latex
    pre.appendChild(code)
    el.replaceWith(pre)
  })
}

/**
 * 편집 전용 스캐폴딩 정리:
 *  - ProseMirror가 넣는 빈 위젯/장식(.ProseMirror-widget, gap cursor, separator)을 제거.
 *  - hardbreak 노드(<span data-type="hardbreak">)를 의미론적 <br>로 치환.
 *  - 리스트의 data-spread 같은 편집용 속성 제거.
 */
function stripEditorScaffolding(root: HTMLElement): void {
  root
    .querySelectorAll('.ProseMirror-widget, .ProseMirror-gapcursor, .ProseMirror-separator')
    .forEach((el) => el.remove())
  root.querySelectorAll('[data-type="hardbreak"]').forEach((el) => {
    el.replaceWith(el.ownerDocument.createElement('br'))
  })
  root.querySelectorAll('ul[data-spread], ol[data-spread]').forEach((el) => {
    el.removeAttribute('data-spread')
  })
}

/**
 * Find 기능이 남긴 .search-match / .search-match-current 데코레이션 span을 언랩한다.
 * 안쪽 텍스트(자식 노드)는 보존하고 span 껍데기만 제거해, 검색 하이라이트가
 * 내보낸 파일에 남지 않게 한다.
 */
function unwrapSearchMatches(root: HTMLElement): void {
  const spans = Array.from(root.querySelectorAll('span.search-match, span.search-match-current'))
  for (const span of spans) {
    const parent = span.parentNode
    if (!parent) continue
    while (span.firstChild) parent.insertBefore(span.firstChild, span)
    parent.removeChild(span)
  }
}

/**
 * URL 문자열의 "스킴 부분"을 우회 시도까지 흡수해 정규화한다.
 *
 * 공격자는 `JavaScript:`, ` javascript:`(앞 공백), `java\tscript:`(탭),
 * `java\nscript:`(개행) 같은 변형으로 단순 문자열 비교를 회피하려 한다.
 * 브라우저는 스킴을 해석할 때 앞뒤 공백을 떼고 스킴 안의 ASCII 제어문자(탭/개행 등)를
 * 무시하므로, 우리도 동일하게:
 *   1) 앞뒤 공백 제거(trim)
 *   2) ASCII 제어문자(0x00–0x1F, 0x7F)와 모든 공백문자 제거
 *   3) 소문자화
 * 한 뒤 비교한다. (제어문자/공백은 정상 URL의 의미 있는 부분이 아니므로 전체에서 제거해도 안전하다.)
 */
function normalizeUrlForSchemeCheck(raw: string): string {
  return raw
    .trim()
    // ASCII 제어문자(0x00–0x1F, 0x7F)와 모든 공백문자(\s)를 함께 제거한다(java\tscript: 같은 우회 흡수).
    .replace(/[\x00-\x1f\x7f\s]/g, '')
    .toLowerCase()
}

/**
 * 정규화한 URL이 위험한 스킴(javascript:, data:, vbscript: 등)을 가지는지 검사하기 위한,
 * "스킴을 가진 URL"의 정의. RFC 3986 의 scheme 문법(첫 글자는 알파벳, 이후 알파벳/숫자/+/-/.)을 따른다.
 * 매칭되지 않으면(스킴 없음) 상대경로/앵커/쿼리이므로 허용 대상이다.
 */
const SCHEME_RE = /^[a-z][a-z0-9+.-]*:/

/**
 * a[href] 스킴 화이트리스트 검사(FIX #1).
 *
 * 허용: http:, https:, mailto:, 그리고 스킴이 없는 상대/앵커/프래그먼트 URL
 *   (스킴 없음, 또는 / # ? . 로 시작 — 프로토콜 상대 //host 는 스킴이 없으므로 그대로 허용).
 * 그 외(javascript:, data:, vbscript:, file:, blob:, about: …)는 href 속성을 제거하고
 * 보이는 텍스트는 유지한다(링크는 죽지만 내용은 남는다).
 */
function sanitizeLinkHrefs(root: HTMLElement): void {
  const anchors = Array.from(root.querySelectorAll('a[href]'))
  for (const a of anchors) {
    const raw = a.getAttribute('href')
    if (raw === null) continue // 방어적: href 없는 <a>는 건드리지 않는다.
    const normalized = normalizeUrlForSchemeCheck(raw)
    // 스킴이 없으면(상대/앵커/쿼리/프로토콜 상대) 안전 → 그대로 둔다.
    const match = normalized.match(SCHEME_RE)
    if (!match) continue
    // 스킴 뒤의 ':'까지 포함된 매칭에서 ':'를 떼어 스킴 이름만 얻는다.
    const scheme = match[0].slice(0, -1)
    if (scheme === 'http' || scheme === 'https' || scheme === 'mailto') continue
    // 위험한 스킴: href를 제거해 무력화(텍스트는 보존).
    a.removeAttribute('href')
  }
}

/**
 * img[src] 스킴 화이트리스트 검사(FIX #2).
 *
 * 허용: data:image/...(앱 자체 붙여넣기/드롭 인라인 이미지)과 http:/https:.
 *   (웹 이미지를 정당하게 참조하는 문서가 있으므로 http/https는 허용한다.)
 * 그 외(javascript:, data: 중 image 가 아닌 것, vbscript:, file: …)는 <img>를 제거한다.
 */
function sanitizeImageSrcs(root: HTMLElement): void {
  const imgs = Array.from(root.querySelectorAll('img[src]'))
  for (const img of imgs) {
    const raw = img.getAttribute('src')
    if (raw === null) continue
    const normalized = normalizeUrlForSchemeCheck(raw)
    const match = normalized.match(SCHEME_RE)
    // src에 스킴이 없으면(상대경로 등) 위험 스킴은 아니지만, 이미지 정규화 경로상
    // 정상 이미지는 data:/http(s) 절대 URL이므로 스킴 없는 src도 그대로 허용한다.
    if (!match) continue
    const scheme = match[0].slice(0, -1)
    if (scheme === 'http' || scheme === 'https') continue
    // data:는 "정적 래스터" 이미지 타입일 때만 허용한다. data:image/svg+xml은 SVG가
    // 능동 포맷(스크립트/onload 포함 가능)이라 제외한다 — 앱 자체는 FileReader로 만든
    // 래스터 data URI만 생성하므로 정상 이미지는 영향 없고, 내보낸 파일의 심층방어가 된다.
    // (img src로 참조된 SVG는 secure-static 모드라 실행은 안 되지만, allowlist 의도와 일치시킨다.)
    if (scheme === 'data' && /^data:image\/(?:png|jpe?g|gif|webp|avif|bmp|x-icon|vnd\.microsoft\.icon)[;,]/.test(normalized)) continue
    // 그 외 위험한 스킴: <img>를 통째로 제거한다.
    img.remove()
  }
}

/**
 * 내보내기 본문 스타일(라이트/다크). `.mallow-export` 컨테이너에 스코프해, HTML 내보내기(<body>
 * 안의 article)와 PDF 내보내기(화면 밖 holder 안의 article) 양쪽에서 동일하게 적용된다.
 * 모든 규칙을 `.mallow-export` 하위로 한정해, PDF holder 같은 외부 컨텍스트의 다른 요소를 건드리지 않는다.
 */
export function exportStyles(dark: boolean): string {
  const c = dark
    ? {
        text: '#e6e6ea',
        bg: '#1c1c1e',
        link: '#4a9eff',
        codeText: '#e6e6ea',
        inlineCodeBg: '#2c2c2e',
        preBg: '#242426',
        quoteText: '#a0a0a8',
        quoteBorder: '#48484c',
        border: '#3a3a3c',
        tableBorder: '#48484c',
      }
    : {
        text: '#1c1c1e',
        bg: '#ffffff',
        link: '#0a6cff',
        codeText: '#1c1c1e',
        inlineCodeBg: '#f0f0f2',
        preBg: '#f6f6f8',
        quoteText: '#555555',
        quoteBorder: '#d0d0d5',
        border: '#e0e0e5',
        tableBorder: '#d8d8dd',
      }
  return `
  .mallow-export {
    box-sizing: border-box;
    max-width: 720px;
    margin: 0 auto;
    padding: 48px 24px;
    font-family: -apple-system, BlinkMacSystemFont, "Apple SD Gothic Neo", system-ui, sans-serif;
    font-size: 16px;
    line-height: 1.7;
    color: ${c.text};
    background: ${c.bg};
  }
  .mallow-export h1, .mallow-export h2, .mallow-export h3,
  .mallow-export h4, .mallow-export h5, .mallow-export h6 { line-height: 1.3; margin: 1.6em 0 0.6em; }
  .mallow-export h1 { font-size: 2em; }
  .mallow-export h2 { font-size: 1.5em; }
  .mallow-export h3 { font-size: 1.25em; }
  .mallow-export :first-child { margin-top: 0; }
  .mallow-export p, .mallow-export ul, .mallow-export ol,
  .mallow-export blockquote, .mallow-export pre, .mallow-export table { margin: 0 0 1em; }
  .mallow-export ul, .mallow-export ol { padding-left: 1.6em; }
  .mallow-export li { margin: 0.2em 0; }
  .mallow-export li[data-checked] { list-style: none; }
  .mallow-export li[data-checked]::before {
    content: "☐";
    display: inline-block;
    width: 1.2em;
    margin-left: -1.4em;
    text-align: left;
  }
  .mallow-export li[data-checked="true"]::before { content: "☑"; }
  .mallow-export a { color: ${c.link}; }
  .mallow-export code {
    font-family: ui-monospace, "SF Mono", Menlo, Monaco, Consolas, monospace;
    font-size: 0.9em;
    color: ${c.codeText};
    background: ${c.inlineCodeBg};
    padding: 0.12em 0.36em;
    border-radius: 4px;
  }
  .mallow-export pre {
    background: ${c.preBg};
    padding: 14px 16px;
    border-radius: 8px;
    overflow: auto;
    /* 긴 코드 줄을 감싼다. PDF는 고정폭 캔버스 스냅샷이라 overflow:auto가 스크롤되지 않아,
       감싸지 않으면 오른쪽 여백에서 잘린다. HTML에서도 가로 넘침을 줄여 더 읽기 좋다. */
    white-space: pre-wrap;
    overflow-wrap: anywhere;
  }
  .mallow-export pre code { background: none; padding: 0; color: ${c.codeText}; }
  .mallow-export blockquote {
    margin-left: 0;
    padding-left: 16px;
    border-left: 3px solid ${c.quoteBorder};
    color: ${c.quoteText};
  }
  .mallow-export img { max-width: 100%; }
  .mallow-export hr { border: none; border-top: 1px solid ${c.border}; margin: 2em 0; }
  .mallow-export table { border-collapse: collapse; width: 100%; }
  .mallow-export th, .mallow-export td { border: 1px solid ${c.tableBorder}; padding: 6px 10px; }`
}

/**
 * 정규화된 본문 HTML을 `.mallow-export` article + 스타일 조각으로 감싼다.
 * HTML 문서(buildHtmlDocument)와 PDF holder가 같은 조각을 공유해 결과가 시각적으로 일치한다.
 */
export function renderExportFragment(bodyHtml: string, dark: boolean): string {
  return `<style>${exportStyles(dark)}</style><article class="mallow-export">${bodyHtml}</article>`
}

/**
 * 본문 HTML을 읽기 좋은 완결된 HTML5 문서로 감싼다.
 *
 * @param dark true면 다크 색 구성(어두운 배경/밝은 텍스트), false면 라이트.
 *   외부 에셋 없이 단일 <style> 안에 색을 모두 담고 color-scheme도 일치시킨다.
 */
export function buildHtmlDocument(title: string, bodyHtml: string, dark: boolean): string {
  const pageBg = dark ? '#1c1c1e' : '#ffffff'
  const scheme = dark ? 'dark' : 'light'
  // 심층 방어(FIX #3): 내보낸 파일은 브라우저에서 열리거나 공유될 수 있으므로,
  // 스킴 검사를 빠져나간 무언가가 있어도 안전하도록 제한적인 CSP meta를 <head>에 박는다.
  //   - default-src 'none' : 스크립트 포함 모든 리소스를 기본 차단(이 문서엔 스크립트가 없다).
  //   - img-src data: http: https: : 임베드된 data-URI 이미지와 웹 이미지(정규화 허용 범위)만.
  //   - style-src 'unsafe-inline' : 문서가 인라인 스타일 한 덩어리로 색을 담으므로 필요.
  //   - font-src data: : 시스템 폰트 스택만 쓰지만 혹시 모를 data: 폰트만 허용.
  //   - base-uri 'none' : base 주입으로 상대 URL을 외부로 돌리는 것을 막는다.
  const csp =
    "default-src 'none'; img-src data: http: https:; style-src 'unsafe-inline'; font-src data:; base-uri 'none'"

  return `<!doctype html>
<html lang="${document.documentElement.lang || 'en'}">
<head>
<meta charset="utf-8" />
<meta http-equiv="Content-Security-Policy" content="${csp}" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<meta name="color-scheme" content="${scheme}" />
<title>${escapeHtml(title)}</title>
<style>
  :root { color-scheme: ${scheme}; }
  html, body { margin: 0; }
  body { background: ${pageBg}; }
${exportStyles(dark)}
</style>
</head>
<body>
<article class="mallow-export">
${bodyHtml}
</article>
</body>
</html>
`
}

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
}
