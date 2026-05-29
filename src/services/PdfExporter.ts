// @ts-ignore html2pdf.js has no built-in types
import html2pdf from 'html2pdf.js'
import { save as saveDialog } from '@tauri-apps/plugin-dialog'
import { writeFile } from '@tauri-apps/plugin-fs'
import { Document } from '../domain/Document'
import { t } from '../i18n'

/**
 * 본문(.ProseMirror)을 클론해 라이트 톤으로 강제한 후 A4 PDF로 내보낸다.
 *
 * Tauri WKWebView는 브라우저식 download(a.click) 트리거를 차단하므로
 * html2pdf의 `.save()` 대신 `.outputPdf('blob')`로 바이너리 버퍼를 받아
 * Tauri saveDialog로 사용자가 고른 경로에 `writeFile`(binary)로 저장한다.
 */
export class PdfExporter {
  /** 진행 중 export 시 중복 호출(빠른 더블클릭, ⌘E + 버튼 클릭 동시) 무시. */
  private isExporting = false

  constructor(private readonly doc: Document) {}

  /**
   * @returns 저장된 경로(성공) 또는 null(사용자가 취소). 호출부가 성공 토스트를 띄울 수 있다.
   *   (빈 문서 차단·"내보낼 내용 없음" 안내는 호출부에서 처리한다 — HTML 내보내기와 동일 정책)
   */
  async export(): Promise<string | null> {
    if (this.isExporting) return null
    const source = document.querySelector('.ProseMirror') as HTMLElement | null
    if (!source) return null

    const base = this.doc.filename.replace(/\.md$/i, '') || t('doc.fallbackName')
    // 저장된 문서면 같은 폴더의 .pdf를 기본값으로(예측 가능), 아니면 이름만. (HtmlExporter와 동일)
    const defaultPath = this.doc.filePath
      ? this.doc.filePath.replace(/\.md$/i, '.pdf')
      : `${base}.pdf`

    // 가드는 dialog 직전에 켜야 dialog가 열려있는 동안에도 중복 호출이 막힌다.
    this.isExporting = true
    try {
      const selected = await saveDialog({
        defaultPath,
        filters: [{ name: 'PDF', extensions: ['pdf'] }],
      })
      if (!selected) return null
      await this.renderAndSave(source, selected)
      return selected
    } finally {
      this.isExporting = false
    }
  }

  /** 실제 PDF 렌더링/저장 — export()에서 user path가 확정된 뒤 호출. */
  private async renderAndSave(source: HTMLElement, selected: string): Promise<void> {

    // 2) 라이트 톤으로 강제 변환할 클론을 화면 밖 holder에 부착.
    const clone = source.cloneNode(true) as HTMLElement
    clone.classList.add('pdf-export')

    const holder = document.createElement('div')
    holder.style.position = 'fixed'
    holder.style.left = '-10000px'
    holder.style.top = '0'
    holder.style.width = '794px'
    holder.style.background = 'white'
    holder.appendChild(clone)
    document.body.appendChild(holder)

    try {
      // 3) PDF를 Blob으로 받음 (save()가 막혀 있으므로 outputPdf 사용).
      const pdfBlob: Blob = await html2pdf()
        .set({
          margin: [15, 15, 15, 15],
          image: { type: 'jpeg', quality: 0.98 },
          html2canvas: { scale: 2, backgroundColor: '#ffffff', useCORS: true },
          jsPDF: { unit: 'mm', format: 'a4', orientation: 'portrait' },
          // 코드블록·이미지·표·인용은 페이지 경계에서 잘리지 않도록 통째로 다음 페이지로 넘긴다.
          pagebreak: { mode: ['css', 'legacy'], avoid: ['pre', 'img', 'table', 'blockquote'] },
        } as any)
        .from(clone)
        .outputPdf('blob')

      // 4) Blob → Uint8Array → 디스크에 저장.
      const arrayBuffer = await pdfBlob.arrayBuffer()
      const bytes = new Uint8Array(arrayBuffer)
      await writeFile(selected, bytes)
    } finally {
      holder.remove()
    }
  }
}
