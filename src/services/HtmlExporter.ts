import { save as saveDialog } from '@tauri-apps/plugin-dialog'
import { writeTextFile } from '@tauri-apps/plugin-fs'
import { Document } from '../domain/Document'
import { t } from '../i18n'

/**
 * 현재 본문(.ProseMirror)을 렌더된 그대로 가져와 독립 실행형 HTML 문서로 내보낸다.
 * 라이트 톤의 간단한 스타일을 함께 임베드해 브라우저에서 바로 읽기 좋게 만든다.
 * (PdfExporter와 동일하게 saveDialog로 사용자가 경로를 고르고 writeTextFile로 저장한다.)
 */
export class HtmlExporter {
  /** 진행 중 중복 호출(빠른 연타, 메뉴+단축키 동시) 무시. */
  private isExporting = false

  constructor(private readonly doc: Document) {}

  async export(): Promise<void> {
    if (this.isExporting) return
    const source = document.querySelector('.ProseMirror') as HTMLElement | null
    if (!source) return

    const base = this.doc.filename.replace(/\.md$/i, '') || t('doc.fallbackName')
    // 저장된 문서면 같은 폴더의 .html을 기본값으로(예측 가능), 아니면 이름만.
    const defaultPath = this.doc.filePath
      ? this.doc.filePath.replace(/\.md$/i, '.html')
      : `${base}.html`

    this.isExporting = true
    try {
      const selected = await saveDialog({
        defaultPath,
        filters: [{ name: 'HTML', extensions: ['html'] }],
      })
      if (!selected) return
      await writeTextFile(selected, buildHtmlDocument(base, source.innerHTML))
    } finally {
      this.isExporting = false
    }
  }
}

/** 본문 HTML을 읽기 좋은 라이트 테마의 완결된 HTML5 문서로 감싼다. */
function buildHtmlDocument(title: string, bodyHtml: string): string {
  return `<!doctype html>
<html lang="${document.documentElement.lang || 'en'}">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>${escapeHtml(title)}</title>
<style>
  :root { color-scheme: light; }
  body {
    max-width: 720px;
    margin: 48px auto;
    padding: 0 24px;
    font-family: -apple-system, BlinkMacSystemFont, "Apple SD Gothic Neo", system-ui, sans-serif;
    font-size: 16px;
    line-height: 1.7;
    color: #1c1c1e;
    background: #ffffff;
  }
  h1, h2, h3, h4, h5, h6 { line-height: 1.3; margin: 1.6em 0 0.6em; }
  h1 { font-size: 2em; }
  h2 { font-size: 1.5em; }
  h3 { font-size: 1.25em; }
  p, ul, ol, blockquote, pre, table { margin: 0 0 1em; }
  a { color: #0a6cff; }
  code {
    font-family: ui-monospace, "SF Mono", Menlo, Monaco, Consolas, monospace;
    font-size: 0.9em;
    background: #f0f0f2;
    padding: 0.12em 0.36em;
    border-radius: 4px;
  }
  pre {
    background: #f6f6f8;
    padding: 14px 16px;
    border-radius: 8px;
    overflow: auto;
  }
  pre code { background: none; padding: 0; }
  blockquote {
    margin-left: 0;
    padding-left: 16px;
    border-left: 3px solid #d0d0d5;
    color: #555;
  }
  img { max-width: 100%; }
  hr { border: none; border-top: 1px solid #e0e0e5; margin: 2em 0; }
  table { border-collapse: collapse; }
  th, td { border: 1px solid #d8d8dd; padding: 6px 10px; }
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
