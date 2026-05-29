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
  // 2) 이미지 블록 → <img>
  normalizeImageBlocks(root)
  // 3) 리스트 wrapper chrome 제거 → 의미론적 <li>
  normalizeListItems(root)
  // 4) 남아있는 Find 하이라이트 span 언랩(텍스트는 보존).
  unwrapSearchMatches(root)

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

      // 내용을 옮긴다: .children > .content-dom 안의 자식들을 <li>로 끌어올린다.
      const contentHosts = innerLi.querySelectorAll('.content-dom')
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
 * 본문 HTML을 읽기 좋은 완결된 HTML5 문서로 감싼다.
 *
 * @param dark true면 다크 색 구성(어두운 배경/밝은 텍스트), false면 라이트.
 *   외부 에셋 없이 단일 <style> 안에 색을 모두 담고 color-scheme도 일치시킨다.
 */
export function buildHtmlDocument(title: string, bodyHtml: string, dark: boolean): string {
  // 라이트/다크 각각의 팔레트. (앱 본문 톤과 비슷하게 맞춤)
  const c = dark
    ? {
        scheme: 'dark',
        bg: '#1c1c1e',
        text: '#e6e6ea',
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
        scheme: 'light',
        bg: '#ffffff',
        text: '#1c1c1e',
        link: '#0a6cff',
        codeText: '#1c1c1e',
        inlineCodeBg: '#f0f0f2',
        preBg: '#f6f6f8',
        quoteText: '#555555',
        quoteBorder: '#d0d0d5',
        border: '#e0e0e5',
        tableBorder: '#d8d8dd',
      }

  return `<!doctype html>
<html lang="${document.documentElement.lang || 'en'}">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<meta name="color-scheme" content="${c.scheme}" />
<title>${escapeHtml(title)}</title>
<style>
  :root { color-scheme: ${c.scheme}; }
  body {
    max-width: 720px;
    margin: 48px auto;
    padding: 0 24px;
    font-family: -apple-system, BlinkMacSystemFont, "Apple SD Gothic Neo", system-ui, sans-serif;
    font-size: 16px;
    line-height: 1.7;
    color: ${c.text};
    background: ${c.bg};
  }
  h1, h2, h3, h4, h5, h6 { line-height: 1.3; margin: 1.6em 0 0.6em; }
  h1 { font-size: 2em; }
  h2 { font-size: 1.5em; }
  h3 { font-size: 1.25em; }
  p, ul, ol, blockquote, pre, table { margin: 0 0 1em; }
  /* 리스트 마커는 CSS가 그린다(인라인 SVG는 정규화에서 제거됨). */
  ul, ol { padding-left: 1.6em; }
  li { margin: 0.2em 0; }
  /* 체크리스트: data-checked 표식으로 박스를 그린다. */
  li[data-checked] { list-style: none; }
  li[data-checked]::before {
    content: "☐";
    display: inline-block;
    width: 1.2em;
    margin-left: -1.4em;
    text-align: left;
  }
  li[data-checked="true"]::before { content: "☑"; }
  a { color: ${c.link}; }
  code {
    font-family: ui-monospace, "SF Mono", Menlo, Monaco, Consolas, monospace;
    font-size: 0.9em;
    color: ${c.codeText};
    background: ${c.inlineCodeBg};
    padding: 0.12em 0.36em;
    border-radius: 4px;
  }
  pre {
    background: ${c.preBg};
    padding: 14px 16px;
    border-radius: 8px;
    overflow: auto;
  }
  pre code { background: none; padding: 0; color: ${c.codeText}; }
  blockquote {
    margin-left: 0;
    padding-left: 16px;
    border-left: 3px solid ${c.quoteBorder};
    color: ${c.quoteText};
  }
  img { max-width: 100%; }
  hr { border: none; border-top: 1px solid ${c.border}; margin: 2em 0; }
  table { border-collapse: collapse; }
  th, td { border: 1px solid ${c.tableBorder}; padding: 6px 10px; }
</style>
</head>
<body>
${bodyHtml}
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
