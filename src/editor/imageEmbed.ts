// ─── 이미지 임베드 헬퍼 ────────────────────────────────────────────
// 붙여넣기/드래그-드롭된 이미지를 base64 data URI로 본문에 인라인 임베드한다(사이드카 파일 없음):
//  - 저장 전 새 문서에서도 동작하고, .md 한 파일로 자체 완결되어 이식이 쉽다
//  - Tauri CSP가 img-src에 data:를 이미 허용하므로 별도 설정/asset 프로토콜이 불필요
//  - blob: URL은 저장 후 깨지므로 쓰지 않는다(data URI는 .md에 그대로 직렬화됨)
// 순수 함수만 모아 두어(에디터/Crepe 의존 없음) 단위 테스트가 쉽다.

/** 너무 큰 이미지는 문서를 비대하게/느리게 만들 수 있어 두는 상한. */
export const MAX_IMAGE_BYTES = 10 * 1024 * 1024 // 10MB

/** MIME 타입이 image/* 인지. */
export function isImageFile(file: File): boolean {
  return file.type.startsWith('image/')
}

/**
 * DataTransfer/Clipboard에서 이미지 파일만 추린다.
 * - files: 드롭과 대부분의 이미지 붙여넣기가 여기로 온다.
 * - items: 일부 WebKit 클립보드 이미지 붙여넣기는 files가 비고 items(file 종류)로만 온다.
 *   files에서 이미 얻었다면 같은 이미지를 두 번 넣지 않도록 건너뛴다.
 */
export function imageFilesFrom(data: DataTransfer | null): File[] {
  if (!data) return []
  const out: File[] = []
  if (data.files) {
    // for-of 동치: for (const f of data.files) if (isImageFile(f)) out.push(f)
    for (const f of Array.from(data.files)) if (isImageFile(f)) out.push(f)
  }
  if (out.length === 0 && data.items) {
    for (const it of Array.from(data.items)) {
      if (it.kind === 'file' && it.type.startsWith('image/')) {
        const f = it.getAsFile()
        if (f) out.push(f)
      }
    }
  }
  return out
}

/** File을 base64 data URI(`data:image/png;base64,...`)로 읽는다. */
export function fileToDataURL(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader()
    reader.onload = () => resolve(String(reader.result))
    reader.onerror = () => reject(reader.error ?? new Error('FileReader error'))
    reader.readAsDataURL(file)
  })
}
