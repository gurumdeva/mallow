import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { normalizeExportHtml, buildHtmlDocument } from '../src/services/HtmlExporter.ts'

/**
 * jsdom에서 crepe의 실제 클론 DOM 구조를 재현한 조각을 만들고,
 * normalizeExportHtml이 에디터 chrome을 벗겨 깔끔한 의미론적 HTML을 내는지 검증한다.
 *
 * 구조는 node_modules/@milkdown 의 실제 node-view 렌더 코드에서 확인한 클래스/계층을 따른다.
 */

/** 주어진 HTML로 .ProseMirror 엘리먼트를 만들어 돌려준다(원본 역할). */
function proseMirror(innerHTML: string): HTMLElement {
  const el = document.createElement('div')
  el.className = 'ProseMirror'
  el.innerHTML = innerHTML
  return el
}

/** normalize 결과를 다시 파싱해 쿼리 가능한 컨테이너로 돌려준다. */
function normalizedDom(innerHTML: string): HTMLElement {
  const out = normalizeExportHtml(proseMirror(innerHTML))
  const holder = document.createElement('div')
  holder.innerHTML = out
  return holder
}

describe('normalizeExportHtml — lists', () => {
  // crepe 불릿 리스트: <ul> > .milkdown-list-item-block > <li.list-item>
  //   > .label-wrapper(인라인 SVG) + .children > .content-dom > <p>
  const bulletList = `
    <ul data-spread="false">
      <div class="milkdown-list-item-block" contenteditable="false">
        <li class="list-item">
          <div class="label-wrapper" contenteditable="false">
            <span class="milkdown-icon label bullet"><svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="3"></circle></svg></span>
          </div>
          <div class="children">
            <div class="content-dom" data-content-dom="true"><p>First item</p></div>
          </div>
        </li>
      </div>
      <div class="milkdown-list-item-block" contenteditable="false">
        <li class="list-item">
          <div class="label-wrapper" contenteditable="false">
            <span class="milkdown-icon label bullet"><svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="3"></circle></svg></span>
          </div>
          <div class="children">
            <div class="content-dom" data-content-dom="true"><p>Second item</p></div>
          </div>
        </li>
      </div>
    </ul>`

  it('produces a clean <ul> with <li> children and no wrapper chrome', () => {
    const dom = normalizedDom(bulletList)

    // <ul>은 그대로 살아있다.
    const ul = dom.querySelector('ul')
    expect(ul).not.toBeNull()

    // 두 개의 <li>로 정규화된다.
    const items = dom.querySelectorAll('li')
    expect(items.length).toBe(2)
    expect(items[0].textContent?.trim()).toBe('First item')
    expect(items[1].textContent?.trim()).toBe('Second item')

    // <li>는 <ul>의 직속 자식이어야 한다(중간 wrapper div 제거됨).
    expect(items[0].parentElement?.tagName).toBe('UL')
  })

  it('strips all crepe list chrome (svg bullet, wrappers)', () => {
    const dom = normalizedDom(bulletList)
    const html = dom.innerHTML

    expect(dom.querySelector('.milkdown-list-item-block')).toBeNull()
    expect(dom.querySelector('.label-wrapper')).toBeNull()
    expect(dom.querySelector('.children')).toBeNull()
    expect(dom.querySelector('.content-dom')).toBeNull()
    expect(dom.querySelector('svg')).toBeNull()
    expect(html).not.toContain('milkdown-icon')
    expect(html).not.toContain('<svg')
  })

  it('unwraps the sole paragraph inside each <li>', () => {
    const dom = normalizedDom(bulletList)
    // <li> 안에 <p> 래퍼가 남지 않아야 한다(단락 하나뿐인 경우).
    expect(dom.querySelector('li > p')).toBeNull()
  })

  it('handles ordered lists (<ol>) the same way', () => {
    const orderedList = `
      <ol start="1" data-spread="false">
        <div class="milkdown-list-item-block">
          <li class="list-item">
            <div class="label-wrapper"><span class="milkdown-icon label ordered">1.</span></div>
            <div class="children"><div class="content-dom"><p>Step one</p></div></div>
          </li>
        </div>
      </ol>`
    const dom = normalizedDom(orderedList)
    const ol = dom.querySelector('ol')
    expect(ol).not.toBeNull()
    expect(dom.querySelectorAll('li').length).toBe(1)
    expect(dom.querySelector('li')?.textContent?.trim()).toBe('Step one')
    expect(dom.querySelector('.label-wrapper')).toBeNull()
  })

  it('marks task-list items with data-checked and keeps text', () => {
    const taskList = `
      <ul>
        <div class="milkdown-list-item-block">
          <li class="list-item">
            <div class="label-wrapper"><span class="milkdown-icon label checked"><svg></svg></span></div>
            <div class="children"><div class="content-dom"><p>done task</p></div></div>
          </li>
        </div>
        <div class="milkdown-list-item-block">
          <li class="list-item">
            <div class="label-wrapper"><span class="milkdown-icon label unchecked"><svg></svg></span></div>
            <div class="children"><div class="content-dom"><p>todo task</p></div></div>
          </li>
        </div>
      </ul>`
    const dom = normalizedDom(taskList)
    const items = dom.querySelectorAll('li')
    expect(items.length).toBe(2)
    expect(items[0].getAttribute('data-checked')).toBe('true')
    expect(items[0].textContent?.trim()).toBe('done task')
    expect(items[1].getAttribute('data-checked')).toBe('false')
    expect(items[1].textContent?.trim()).toBe('todo task')
    expect(dom.querySelector('svg')).toBeNull()
  })

  it('preserves nested block content (e.g. a nested list) inside an item', () => {
    // 아이템 안에 단락 + 중첩 리스트가 같이 있는 경우, 단락 unwrap이
    // 일어나지 않고(단일 <p>가 아님) 내용이 보존되어야 한다.
    const nested = `
      <ul>
        <div class="milkdown-list-item-block">
          <li class="list-item">
            <div class="label-wrapper"><span class="milkdown-icon label bullet"><svg></svg></span></div>
            <div class="children">
              <div class="content-dom">
                <p>Parent</p>
                <ul>
                  <div class="milkdown-list-item-block">
                    <li class="list-item">
                      <div class="label-wrapper"><span class="milkdown-icon label bullet"><svg></svg></span></div>
                      <div class="children"><div class="content-dom"><p>Child</p></div></div>
                    </li>
                  </div>
                </ul>
              </div>
            </div>
          </li>
        </div>
      </ul>`
    const dom = normalizedDom(nested)
    // 바깥/안쪽 둘 다 <li>로 남고 chrome은 사라진다.
    expect(dom.querySelector('.milkdown-list-item-block')).toBeNull()
    expect(dom.querySelector('svg')).toBeNull()
    // 부모 텍스트와 자식 텍스트가 모두 보존.
    const text = dom.textContent ?? ''
    expect(text).toContain('Parent')
    expect(text).toContain('Child')
    // 중첩 <ul>이 <li> 안에 존재.
    expect(dom.querySelector('li ul li')).not.toBeNull()
  })
})

describe('normalizeExportHtml — code blocks', () => {
  // (b) CodeMirror 초기화 상태: tools(언어 피커/복사버튼) + codemirror-host(.cm-*)
  const cmCodeBlock = `
    <div class="milkdown-code-block">
      <div class="tools">
        <div class="language-button">JavaScript<div class="expand-icon"><span class="milkdown-icon"><svg></svg></span></div></div>
        <div class="language-picker"><div class="list-wrapper"><ul class="language-list"><li class="language-list-item" data-language="JavaScript">JavaScript</li></ul></div></div>
        <div class="tools-button-group"><button type="button" class="copy-button"><span class="milkdown-icon"><svg></svg></span>Copy</button></div>
      </div>
      <div class="codemirror-host">
        <div class="cm-editor">
          <div class="cm-scroller">
            <div class="cm-gutters"><div class="cm-gutter cm-lineNumbers"><div class="cm-gutterElement">1</div><div class="cm-gutterElement">2</div></div></div>
            <div class="cm-content" contenteditable="true">
              <div class="cm-line">const a = 1</div>
              <div class="cm-line">console.log(a)</div>
            </div>
          </div>
        </div>
      </div>
      <div class="preview-panel"><div class="preview"></div></div>
    </div>`

  it('replaces a CodeMirror block with a plain <pre><code> of just the code', () => {
    const dom = normalizedDom(cmCodeBlock)
    const pre = dom.querySelector('pre')
    const code = dom.querySelector('pre > code')
    expect(pre).not.toBeNull()
    expect(code).not.toBeNull()
    expect(code?.textContent).toBe('const a = 1\nconsole.log(a)')
  })

  it('strips all CodeMirror / picker / preview chrome', () => {
    const dom = normalizedDom(cmCodeBlock)
    const html = dom.innerHTML
    expect(dom.querySelector('.milkdown-code-block')).toBeNull()
    expect(dom.querySelector('.cm-editor')).toBeNull()
    expect(dom.querySelector('.cm-content')).toBeNull()
    expect(dom.querySelector('.cm-gutters')).toBeNull()
    expect(dom.querySelector('.cm-line')).toBeNull()
    expect(dom.querySelector('.language-button')).toBeNull()
    expect(dom.querySelector('.language-picker')).toBeNull()
    expect(dom.querySelector('.copy-button')).toBeNull()
    expect(dom.querySelector('.preview-panel')).toBeNull()
    // 줄번호 "1"/"2"나 "Copy" 같은 chrome 텍스트가 코드에 새어들지 않아야 한다.
    expect(html).not.toContain('cm-')
    expect(html).not.toContain('language-button')
    expect(dom.querySelector('code')?.textContent).not.toContain('Copy')
  })

  it('carries the language as class="language-xxx" on <code>', () => {
    const dom = normalizedDom(cmCodeBlock)
    const code = dom.querySelector('code')
    expect(code?.className).toBe('language-javascript')
  })

  it('reads language from data-language on the wrapper when present', () => {
    const withDataLang = `
      <div class="milkdown-code-block" data-language="Python">
        <pre class="milkdown-code-block-placeholder"><code>print(1)</code></pre>
      </div>`
    const dom = normalizedDom(withDataLang)
    expect(dom.querySelector('code')?.className).toBe('language-python')
    expect(dom.querySelector('code')?.textContent).toBe('print(1)')
  })

  it('handles the placeholder (un-initialized) state: <pre.placeholder><code>', () => {
    const placeholder = `
      <div class="milkdown-code-block">
        <pre class="milkdown-code-block-placeholder"><code>let x = 2\nx + 1</code></pre>
      </div>`
    const dom = normalizedDom(placeholder)
    const code = dom.querySelector('pre > code')
    expect(code?.textContent).toBe('let x = 2\nx + 1')
    expect(dom.querySelector('.milkdown-code-block-placeholder')).toBeNull()
  })

  it('omits the language class when language is unknown ("Text" placeholder)', () => {
    const noLang = `
      <div class="milkdown-code-block">
        <div class="tools"><div class="language-button">Text<div class="expand-icon"></div></div></div>
        <div class="codemirror-host"><div class="cm-editor"><div class="cm-content"><div class="cm-line">plain</div></div></div></div>
      </div>`
    const dom = normalizedDom(noLang)
    const code = dom.querySelector('code')
    expect(code?.getAttribute('class')).toBeNull()
    expect(code?.textContent).toBe('plain')
  })

  it('escapes HTML-special characters in the code text', () => {
    const withAngles = `
      <div class="milkdown-code-block">
        <pre class="milkdown-code-block-placeholder"><code>&lt;div&gt; &amp; &lt;/div&gt;</code></pre>
      </div>`
    const out = normalizeExportHtml(proseMirror(withAngles))
    // 출력 문자열에는 이스케이프된 형태로 들어가야 한다(생 <div>가 아님).
    expect(out).toContain('&lt;div&gt;')
    expect(out).not.toContain('<div>')
    // 그리고 다시 파싱하면 원문 텍스트로 복원.
    const dom = document.createElement('div')
    dom.innerHTML = out
    expect(dom.querySelector('code')?.textContent).toBe('<div> & </div>')
  })
})

describe('normalizeExportHtml — image blocks', () => {
  const dataUri =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='

  const imageBlock = `
    <div class="milkdown-image-block">
      <div class="image-wrapper">
        <div class="operation"><div class="operation-item"><span class="milkdown-icon"><svg></svg></span></div></div>
        <img src="${dataUri}" alt="a cat" />
        <div class="image-resize-handle"></div>
      </div>
      <input class="caption-input" placeholder="Image caption" value="" />
    </div>`

  it('normalizes the image block to a bare <img> with the data-URI src preserved', () => {
    const dom = normalizedDom(imageBlock)
    const imgs = dom.querySelectorAll('img')
    expect(imgs.length).toBe(1)
    expect(imgs[0].getAttribute('src')).toBe(dataUri)
    expect(imgs[0].getAttribute('alt')).toBe('a cat')
  })

  it('strips image-block chrome (wrapper, operation buttons, resize handle, caption input)', () => {
    const dom = normalizedDom(imageBlock)
    expect(dom.querySelector('.milkdown-image-block')).toBeNull()
    expect(dom.querySelector('.image-wrapper')).toBeNull()
    expect(dom.querySelector('.operation')).toBeNull()
    expect(dom.querySelector('.image-resize-handle')).toBeNull()
    expect(dom.querySelector('.caption-input')).toBeNull()
    expect(dom.querySelector('svg')).toBeNull()
    // <img>는 wrapper 밖, 즉 더 이상 .image-wrapper 안에 있지 않다.
    expect(dom.querySelector('img')?.closest('.image-wrapper')).toBeNull()
  })

  it('falls back to the caption input value for alt when img has no alt', () => {
    const withCaption = `
      <div class="milkdown-image-block">
        <div class="image-wrapper">
          <img src="${dataUri}" alt="" />
          <div class="image-resize-handle"></div>
        </div>
        <input class="caption-input" value="my caption" />
      </div>`
    const dom = normalizedDom(withCaption)
    expect(dom.querySelector('img')?.getAttribute('alt')).toBe('my caption')
  })
})

describe('normalizeExportHtml — Find highlights', () => {
  it('unwraps .search-match spans, keeping the inner text', () => {
    const withMatch = `<p>hello <span class="search-match">wor</span>ld</p>`
    const dom = normalizedDom(withMatch)
    expect(dom.querySelector('.search-match')).toBeNull()
    expect(dom.querySelector('span')).toBeNull()
    expect(dom.querySelector('p')?.textContent).toBe('hello world')
  })

  it('unwraps .search-match-current too', () => {
    const withCurrent = `<p>a <span class="search-match search-match-current">B</span> c</p>`
    const dom = normalizedDom(withCurrent)
    expect(dom.querySelector('.search-match-current')).toBeNull()
    expect(dom.querySelector('.search-match')).toBeNull()
    expect(dom.querySelector('p')?.textContent).toBe('a B c')
  })

  it('leaves non-search spans untouched', () => {
    const other = `<p><span class="other">keep me</span></p>`
    const dom = normalizedDom(other)
    expect(dom.querySelector('span.other')).not.toBeNull()
    expect(dom.querySelector('p')?.textContent).toBe('keep me')
  })
})

describe('normalizeExportHtml — purity', () => {
  it('does not mutate the source element', () => {
    const src = proseMirror(
      `<div class="milkdown-code-block"><pre class="milkdown-code-block-placeholder"><code>x</code></pre></div>`,
    )
    const before = src.innerHTML
    normalizeExportHtml(src)
    // 원본은 그대로여야 한다(깊은 클론 위에서만 작업).
    expect(src.innerHTML).toBe(before)
    expect(src.querySelector('.milkdown-code-block')).not.toBeNull()
  })

  it('keeps ordinary content (headings, paragraphs, inline code) intact', () => {
    const dom = normalizedDom(
      `<h1>Title</h1><p>Some <code>inline</code> text</p>`,
    )
    expect(dom.querySelector('h1')?.textContent).toBe('Title')
    expect(dom.querySelector('p code')?.textContent).toBe('inline')
  })
})

describe('buildHtmlDocument', () => {
  it('wraps body HTML in a complete HTML5 document with the title', () => {
    const html = buildHtmlDocument('My Doc', '<p>hi</p>', false)
    expect(html.startsWith('<!doctype html>')).toBe(true)
    expect(html).toContain('<title>My Doc</title>')
    expect(html).toContain('<p>hi</p>')
    expect(html).toContain('</html>')
  })

  it('escapes the title', () => {
    const html = buildHtmlDocument('a & <b> "c"', '', false)
    expect(html).toContain('<title>a &amp; &lt;b&gt; &quot;c&quot;</title>')
  })

  it('emits a light color scheme + light background in light mode', () => {
    const html = buildHtmlDocument('t', '', false)
    expect(html).toContain('color-scheme: light')
    expect(html).toContain('content="light"')
    expect(html).toContain('background: #ffffff')
    // 라이트에는 다크 배경이 없어야 한다.
    expect(html).not.toContain('background: #1c1c1e')
  })

  it('emits a dark color scheme + dark background in dark mode', () => {
    const html = buildHtmlDocument('t', '', true)
    expect(html).toContain('color-scheme: dark')
    expect(html).toContain('content="dark"')
    expect(html).toContain('background: #1c1c1e')
    // 다크에는 라이트 본문 배경이 없어야 한다.
    expect(html).not.toContain('background: #ffffff')
  })

  it('light vs dark documents differ in background/scheme', () => {
    const light = buildHtmlDocument('t', '<p>x</p>', false)
    const dark = buildHtmlDocument('t', '<p>x</p>', true)
    expect(light).not.toBe(dark)
    expect(light).toContain('color-scheme: light')
    expect(dark).toContain('color-scheme: dark')
  })

  it('is self-contained (no external stylesheet/script references)', () => {
    const html = buildHtmlDocument('t', '<p>x</p>', true)
    expect(html).not.toContain('<link')
    expect(html).not.toContain('<script')
    // 스타일은 인라인 <style> 한 덩어리.
    expect((html.match(/<style>/g) ?? []).length).toBe(1)
  })
})

describe('buildHtmlDocument — lang attribute', () => {
  let original: string

  beforeEach(() => {
    original = document.documentElement.lang
  })
  afterEach(() => {
    document.documentElement.lang = original
  })

  it('uses document lang when set', () => {
    document.documentElement.lang = 'ko'
    expect(buildHtmlDocument('t', '', false)).toContain('<html lang="ko">')
  })

  it('falls back to "en" when document lang is empty', () => {
    document.documentElement.lang = ''
    expect(buildHtmlDocument('t', '', false)).toContain('<html lang="en">')
  })
})
