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

describe('normalizeExportHtml — link href sanitization (XSS)', () => {
  /** href로 <a>를 만든 뒤 normalize 결과에서 그 <a>를 찾아 돌려준다. */
  function anchorAfterNormalize(href: string): HTMLAnchorElement | null {
    // 속성값에 "가 섞여도 안전하게 setAttribute로 주입한다.
    const a = document.createElement('a')
    a.setAttribute('href', href)
    a.textContent = 'click me'
    const pm = document.createElement('div')
    pm.className = 'ProseMirror'
    pm.appendChild(a)
    const holder = document.createElement('div')
    holder.innerHTML = normalizeExportHtml(pm)
    return holder.querySelector('a')
  }

  it('neutralizes a javascript: href but keeps the visible text', () => {
    const a = anchorAfterNormalize('javascript:alert(1)')
    expect(a).not.toBeNull()
    expect(a?.hasAttribute('href')).toBe(false)
    expect(a?.textContent).toBe('click me')
  })

  it('neutralizes a data:text/html href', () => {
    const a = anchorAfterNormalize('data:text/html,<script>alert(1)</script>')
    expect(a?.hasAttribute('href')).toBe(false)
  })

  it('neutralizes a vbscript: href', () => {
    const a = anchorAfterNormalize('vbscript:msgbox(1)')
    expect(a?.hasAttribute('href')).toBe(false)
  })

  it('catches control-char / casing bypasses (java\\tscript:, JavaScript:, leading space)', () => {
    expect(anchorAfterNormalize('java\tscript:alert(1)')?.hasAttribute('href')).toBe(false)
    expect(anchorAfterNormalize('java\nscript:alert(1)')?.hasAttribute('href')).toBe(false)
    expect(anchorAfterNormalize('JavaScript:alert(1)')?.hasAttribute('href')).toBe(false)
    expect(anchorAfterNormalize('  javascript:alert(1)')?.hasAttribute('href')).toBe(false)
    // 스킴 앞에 제어문자가 섞인 형태(\x01javascript:)도 trim/strip 후 잡힌다.
    expect(anchorAfterNormalize('javascript:alert(1)')?.hasAttribute('href')).toBe(false)
  })

  it('keeps http/https hrefs intact', () => {
    expect(anchorAfterNormalize('http://example.com/x')?.getAttribute('href')).toBe(
      'http://example.com/x',
    )
    expect(anchorAfterNormalize('https://example.com/x?q=1#h')?.getAttribute('href')).toBe(
      'https://example.com/x?q=1#h',
    )
  })

  it('keeps mailto: hrefs intact', () => {
    expect(anchorAfterNormalize('mailto:foo@bar.com')?.getAttribute('href')).toBe(
      'mailto:foo@bar.com',
    )
  })

  it('keeps relative / anchor / fragment / query hrefs intact', () => {
    expect(anchorAfterNormalize('/about')?.getAttribute('href')).toBe('/about')
    expect(anchorAfterNormalize('#section')?.getAttribute('href')).toBe('#section')
    expect(anchorAfterNormalize('?q=1')?.getAttribute('href')).toBe('?q=1')
    expect(anchorAfterNormalize('./relative/path.html')?.getAttribute('href')).toBe(
      './relative/path.html',
    )
    expect(anchorAfterNormalize('page.html')?.getAttribute('href')).toBe('page.html')
  })

  it('keeps protocol-relative //host hrefs (no scheme present)', () => {
    expect(anchorAfterNormalize('//cdn.example.com/x')?.getAttribute('href')).toBe(
      '//cdn.example.com/x',
    )
  })

  it('leaves an <a> without href untouched', () => {
    const a = document.createElement('a')
    a.textContent = 'no href'
    const pm = document.createElement('div')
    pm.className = 'ProseMirror'
    pm.appendChild(a)
    const holder = document.createElement('div')
    holder.innerHTML = normalizeExportHtml(pm)
    const out = holder.querySelector('a')
    expect(out).not.toBeNull()
    expect(out?.hasAttribute('href')).toBe(false)
    expect(out?.textContent).toBe('no href')
  })
})

describe('normalizeExportHtml — image src sanitization (XSS)', () => {
  const pngDataUri =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='

  /** src로 <img>를 만든 뒤 normalize 결과 컨테이너를 돌려준다(img가 살았는지/죽었는지 확인용). */
  function imgAfterNormalize(src: string): HTMLElement {
    const img = document.createElement('img')
    img.setAttribute('src', src)
    const pm = document.createElement('div')
    pm.className = 'ProseMirror'
    pm.appendChild(img)
    const holder = document.createElement('div')
    holder.innerHTML = normalizeExportHtml(pm)
    return holder
  }

  it('drops an <img> with a javascript: src', () => {
    expect(imgAfterNormalize('javascript:alert(1)').querySelector('img')).toBeNull()
  })

  it('drops an <img> with a non-image data: src (data:text/html)', () => {
    expect(
      imgAfterNormalize('data:text/html,<script>alert(1)</script>').querySelector('img'),
    ).toBeNull()
  })

  it('drops an <img> with a vbscript: / file: src', () => {
    expect(imgAfterNormalize('vbscript:msgbox(1)').querySelector('img')).toBeNull()
    expect(imgAfterNormalize('file:///etc/passwd').querySelector('img')).toBeNull()
  })

  it('catches control-char bypass in img src (data:\\timage/...-style fakes)', () => {
    // "data:image" 처럼 보이지만 실제로는 image 타입이 아닌 경우 → 제거.
    expect(imgAfterNormalize('data:imagex/png;base64,AAAA').querySelector('img')).toBeNull()
  })

  it('keeps a data:image/... src', () => {
    const img = imgAfterNormalize(pngDataUri).querySelector('img')
    expect(img).not.toBeNull()
    expect(img?.getAttribute('src')).toBe(pngDataUri)
  })

  it('drops data:image/svg+xml (active format) but keeps raster data URIs', () => {
    // SVG는 스크립트/onload를 품을 수 있는 능동 포맷이라 래스터 화이트리스트에서 제외한다.
    expect(
      imgAfterNormalize('data:image/svg+xml,<svg onload=alert(1)></svg>').querySelector('img'),
    ).toBeNull()
    expect(
      imgAfterNormalize('data:image/svg+xml;base64,PHN2Zz48L3N2Zz4=').querySelector('img'),
    ).toBeNull()
    // 콤마 형식(비-base64) 래스터도 허용된다(앱은 ;base64를 쓰지만 손수 작성 가능).
    expect(
      imgAfterNormalize('data:image/gif,GIF89a').querySelector('img'),
    ).not.toBeNull()
  })

  it('keeps http/https image srcs', () => {
    expect(
      imgAfterNormalize('https://example.com/a.png').querySelector('img')?.getAttribute('src'),
    ).toBe('https://example.com/a.png')
    expect(
      imgAfterNormalize('http://example.com/a.png').querySelector('img')?.getAttribute('src'),
    ).toBe('http://example.com/a.png')
  })
})

describe('buildHtmlDocument — CSP meta (defense-in-depth)', () => {
  it('embeds a restrictive Content-Security-Policy meta in <head>', () => {
    const html = buildHtmlDocument('t', '<p>x</p>', false)
    expect(html).toContain('http-equiv="Content-Security-Policy"')
    // 핵심 디렉티브들이 모두 들어있는지.
    expect(html).toContain("default-src 'none'")
    expect(html).toContain('img-src data: http: https:')
    expect(html).toContain("style-src 'unsafe-inline'")
    expect(html).toContain('base-uri')
    // 스크립트는 어디에도 허용되지 않아야 한다(script-src 디렉티브 자체가 없음 → default-src 'none' 적용).
    expect(html).not.toContain('script-src')
  })

  it('keeps the color-scheme meta + inline <style> alongside the CSP (legit content not broken)', () => {
    const dark = buildHtmlDocument('t', '<p>x</p>', true)
    expect(dark).toContain('name="color-scheme"')
    expect(dark).toContain('content="dark"')
    expect(dark).toContain('<style>')
    // CSP가 들어와도 본문은 그대로 임베드된다.
    expect(dark).toContain('<p>x</p>')
  })
})

describe('normalizeExportHtml — tables', () => {
  // crepe 표 클론(실제 구조 축약): .milkdown-table-block 안에 드래그 핸들/추가 버튼/빈 미리보기
  // 표가 잔뜩 있고, 진짜 내용은 table.children > tbody.content-dom 안에 있다.
  const tableBlock = `
    <div class="milkdown-table-block" data-v-app="">
      <div>
        <div data-role="col-drag-handle" class="handle cell-handle"><span class="milkdown-icon"><svg viewBox="0 0 16 16"><path d="M3"></path></svg></span><div class="button-group"><button type="button"><span class="milkdown-icon"><svg><path d="x"></path></svg></span></button></div></div>
        <div data-role="row-drag-handle" class="handle cell-handle"><span class="milkdown-icon"><svg><path></path></svg></span></div>
        <div class="table-wrapper">
          <div class="drag-preview" data-direction="vertical"><table><tbody></tbody></table></div>
          <div data-role="x-line-drag-handle" class="handle line-handle"><button type="button" class="add-button"><span class="milkdown-icon"><svg><path></path></svg></span></button></div>
          <table class="children"><tbody data-content-dom="true" class="content-dom">
            <tr data-is-header="true"><th style="text-align: left;"><p>Feature</p></th><th style="text-align: right;"><p>Status</p></th></tr>
            <tr><td style="text-align: left;"><p>Headings</p></td><td style="text-align: right;"><p>Done</p></td></tr>
          </tbody></table>
        </div>
      </div>
    </div>`

  it('produces one clean <table> with the real rows and drops the empty drag-preview table', () => {
    const dom = normalizedDom(tableBlock)
    const tables = dom.querySelectorAll('table')
    expect(tables.length).toBe(1) // 빈 drag-preview 표는 버려진다
    const rows = dom.querySelectorAll('tr')
    expect(rows.length).toBe(2)
    expect(dom.querySelectorAll('th').length).toBe(2)
    expect(dom.querySelectorAll('td').length).toBe(2)
  })

  it('keeps cell text + alignment and unwraps the cell <p>', () => {
    const dom = normalizedDom(tableBlock)
    const ths = dom.querySelectorAll('th')
    expect(ths[0].textContent?.trim()).toBe('Feature')
    expect(ths[1].textContent?.trim()).toBe('Status')
    expect((ths[0] as HTMLElement).style.textAlign).toBe('left')
    expect((ths[1] as HTMLElement).style.textAlign).toBe('right')
    // 셀 안 <p>는 풀려 셀 직속 텍스트가 된다.
    expect(ths[0].querySelector('p')).toBeNull()
    const tds = dom.querySelectorAll('td')
    expect(tds[0].textContent?.trim()).toBe('Headings')
    expect(tds[0].querySelector('p')).toBeNull()
  })

  it('strips all table editing chrome (handles, buttons, svg, wrappers, content-dom)', () => {
    const dom = normalizedDom(tableBlock)
    const html = dom.innerHTML
    expect(dom.querySelector('.milkdown-table-block')).toBeNull()
    expect(dom.querySelector('.handle')).toBeNull()
    expect(dom.querySelector('button')).toBeNull()
    expect(dom.querySelector('svg')).toBeNull()
    expect(dom.querySelector('.drag-preview')).toBeNull()
    expect(dom.querySelector('.content-dom')).toBeNull()
    expect(html).not.toContain('add-button')
    expect(html).not.toContain('data-role')
  })

  it('preserves a cell with a paragraph AND a nested list (no content loss, regression)', () => {
    // 셀이 단순 <p>가 아니라 <p> + 중첩 리스트를 가질 때, 예전엔 하위 content-dom만 남기고
    // 나머지(셀의 <p>와 리스트 wrapper)를 버렸다. 둘 다 보존돼야 한다.
    const cellWithList = `
      <div class="milkdown-table-block">
        <div class="table-wrapper">
          <table class="children"><tbody data-content-dom="true" class="content-dom">
            <tr><td style="text-align: left;">
              <p>real cell text</p>
              <ul data-spread="false"><div class="milkdown-list-item-block"><li class="list-item">
                <div class="label-wrapper"><span class="milkdown-icon label bullet"><svg></svg></span></div>
                <div class="children"><div class="content-dom" data-content-dom="true"><p>nested</p></div></div>
              </li></div></ul>
            </td></tr>
          </tbody></table>
        </div>
      </div>`
    const dom = normalizedDom(cellWithList)
    const td = dom.querySelector('td')!
    expect(td.textContent).toContain('real cell text') // 셀의 본문 단락이 보존됨
    const li = td.querySelector('ul li') // 중첩 리스트가 정규화돼 보존됨
    expect(li?.textContent?.trim()).toBe('nested')
  })
})

describe('normalizeExportHtml — nested lists (regression)', () => {
  // 부모 아이템의 content-dom 안에 중첩 <ul>이 들어 있는 구조. 예전엔 재귀 querySelectorAll로
  // 중첩 아이템의 content-dom까지 부모로 끌어올려, 중첩 <li>가 비고 텍스트가 부모로 새어 나갔다.
  const nested = `
    <ul data-spread="false">
      <div class="milkdown-list-item-block"><li class="list-item">
        <div class="label-wrapper"><span class="milkdown-icon label bullet"><svg></svg></span></div>
        <div class="children"><div class="content-dom" data-content-dom="true">
          <p>Parent</p>
          <ul data-spread="false">
            <div class="milkdown-list-item-block"><li class="list-item">
              <div class="label-wrapper"><span class="milkdown-icon label bullet"><svg></svg></span></div>
              <div class="children"><div class="content-dom" data-content-dom="true"><p>Child</p></div></div>
            </li></div>
          </ul>
        </div></div>
      </li></div>
    </ul>`

  it('keeps nested item text inside a nested <ul><li>, not hoisted/emptied', () => {
    const dom = normalizedDom(nested)
    const items = dom.querySelectorAll('li')
    expect(items.length).toBe(2)
    // 빈 <li>가 없어야 한다(회귀 버그의 증상).
    items.forEach((li) => expect(li.textContent?.trim()).not.toBe(''))
    // 중첩 <ul>은 부모 <li> 안에 있고, 그 안의 <li>가 "Child"를 담는다.
    const parent = Array.from(items).find((li) => li.textContent?.includes('Parent'))!
    const nestedUl = parent.querySelector('ul')
    expect(nestedUl).not.toBeNull()
    expect(nestedUl!.querySelector('li')?.textContent?.trim()).toBe('Child')
  })
})

describe('normalizeExportHtml — math', () => {
  it('replaces inline KaTeX with the LaTeX source in <code>', () => {
    const dom = normalizedDom(
      '<p>x <span data-type="math_inline" data-value="E = mc^2"><span class="katex"><span class="katex-mathml">Emc2</span><span class="katex-html">Emc2</span></span></span> y</p>',
    )
    const code = dom.querySelector('code')
    expect(code?.textContent).toBe('E = mc^2')
    expect(dom.querySelector('.katex')).toBeNull()
    expect(dom.querySelector('[data-type="math_inline"]')).toBeNull()
  })

  it('replaces block math with <pre><code> LaTeX source', () => {
    const dom = normalizedDom('<div data-type="math_block" data-value="\\int_0^1 x"></div>')
    const pre = dom.querySelector('pre')
    expect(pre?.querySelector('code')?.textContent).toBe('\\int_0^1 x')
    expect(dom.querySelector('[data-type="math_block"]')).toBeNull()
  })

  // math:'mathml' 모드 — HTML 내보내기에서 진짜 수식으로 렌더되도록 네이티브 <math>를 남긴다.
  const mathmlMode = (innerHTML: string): HTMLElement => {
    const holder = document.createElement('div')
    holder.innerHTML = normalizeExportHtml(proseMirror(innerHTML), { math: 'mathml' })
    return holder
  }

  it("keeps native <math> for inline math in 'mathml' mode and drops the katex-html chrome", () => {
    const dom = mathmlMode(
      '<p>x <span data-type="math_inline" data-value="E=mc^2"><span class="katex"><span class="katex-mathml"><math xmlns="http://www.w3.org/1998/Math/MathML"><mrow><mi>E</mi></mrow></math></span><span class="katex-html">JUNK</span></span></span> y</p>',
    )
    expect(dom.querySelector('math')).not.toBeNull()
    expect(dom.querySelector('.katex-html')).toBeNull()
    expect(dom.querySelector('.katex')).toBeNull()
    expect(dom.querySelector('[data-type="math_inline"]')).toBeNull()
    expect(dom.innerHTML).not.toContain('JUNK') // 시각용 KaTeX HTML은 제거됨
  })

  it("marks block math <math display=\"block\"> in 'mathml' mode", () => {
    const dom = mathmlMode(
      '<div data-type="math_block" data-value="x"><span class="katex-display"><span class="katex"><span class="katex-mathml"><math xmlns="http://www.w3.org/1998/Math/MathML"><mrow><mi>x</mi></mrow></math></span><span class="katex-html">J</span></span></span></div>',
    )
    const math = dom.querySelector('math')
    expect(math).not.toBeNull()
    expect(math?.getAttribute('display')).toBe('block')
    expect(dom.querySelector('.katex-html')).toBeNull()
  })

  it("falls back to LaTeX source in 'mathml' mode when no <math> is present", () => {
    const dom = mathmlMode('<span data-type="math_inline" data-value="a+b"></span>')
    expect(dom.querySelector('math')).toBeNull()
    expect(dom.querySelector('code')?.textContent).toBe('a+b')
  })
})

describe('normalizeExportHtml — editor scaffolding', () => {
  it('removes empty ProseMirror widgets and converts hardbreak to <br>', () => {
    const dom = normalizedDom(
      '<div class="ProseMirror-widget"></div><p>Hello<span data-type="hardbreak" data-is-inline="true"> </span>World</p>',
    )
    expect(dom.querySelector('.ProseMirror-widget')).toBeNull()
    expect(dom.querySelector('[data-type="hardbreak"]')).toBeNull()
    expect(dom.querySelector('p br')).not.toBeNull()
  })

  it('strips the editor-only data-spread attribute from lists', () => {
    const dom = normalizedDom(
      '<ul data-spread="false"><div class="milkdown-list-item-block"><li class="list-item"><div class="label-wrapper"><span class="milkdown-icon label bullet"><svg></svg></span></div><div class="children"><div class="content-dom" data-content-dom="true"><p>x</p></div></div></li></div></ul>',
    )
    expect(dom.querySelector('ul[data-spread]')).toBeNull()
  })
})
