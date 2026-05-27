// @ts-ignore html2pdf.js has no built-in types
import html2pdf from 'html2pdf.js'
import { save as saveDialog } from '@tauri-apps/plugin-dialog'
import { writeFile } from '@tauri-apps/plugin-fs'
import { Document } from '../domain/Document'

/**
 * 본문(.ProseMirror)을 클론해 라이트 톤으로 강제한 후 A4 PDF로 내보낸다.
 *
 * Tauri WKWebView는 브라우저식 download(a.click) 트리거를 차단하므로
 * html2pdf의 `.save()` 대신 `.outputPdf('blob')`로 바이너리 버퍼를 받아
 * Tauri saveDialog로 사용자가 고른 경로에 `writeFile`(binary)로 저장한다.
 */
export class PdfExporter {
  constructor(private readonly doc: Document) {}

  async export(): Promise<void> {
    const source = document.querySelector('.ProseMirror') as HTMLElement | null
    if (!source) return

    const filenameBase = this.doc.filename.replace(/\.md$/, '') || '문서'

    // 1) 사용자 path 선택. 취소하면 즉시 종료 (PDF 렌더링 비용 없이).
    const selected = await saveDialog({
      defaultPath: `${filenameBase}.pdf`,
      filters: [{ name: 'PDF', extensions: ['pdf'] }],
    })
    if (!selected) return

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
          pagebreak: { mode: ['css', 'legacy'] },
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
