import { describe, it, expect } from 'vitest'
import {
  MAX_IMAGE_BYTES,
  isImageFile,
  imageFilesFrom,
  fileToDataURL,
} from '../src/editor/imageEmbed.ts'

// jsdom의 File/Blob을 사용해 테스트용 File을 만든다.
function file(name: string, type: string, content = 'x'): File {
  return new File([content], name, { type })
}

describe('isImageFile', () => {
  it('is true for image/* MIME types', () => {
    expect(isImageFile(file('a.png', 'image/png'))).toBe(true)
    expect(isImageFile(file('a.jpg', 'image/jpeg'))).toBe(true)
    expect(isImageFile(file('a.svg', 'image/svg+xml'))).toBe(true)
  })

  it('is false for non-image types and empty type', () => {
    expect(isImageFile(file('a.txt', 'text/plain'))).toBe(false)
    expect(isImageFile(file('a.pdf', 'application/pdf'))).toBe(false)
    expect(isImageFile(file('a', ''))).toBe(false)
  })
})

describe('imageFilesFrom', () => {
  it('returns [] for null or a transfer without files', () => {
    expect(imageFilesFrom(null)).toEqual([])
    expect(imageFilesFrom({} as unknown as DataTransfer)).toEqual([])
  })

  it('keeps only image files, preserving order', () => {
    const png = file('a.png', 'image/png')
    const gif = file('b.gif', 'image/gif')
    const txt = file('c.txt', 'text/plain')
    const dt = { files: [png, txt, gif] } as unknown as DataTransfer
    expect(imageFilesFrom(dt)).toEqual([png, gif])
  })

  it('returns [] when no files are images', () => {
    const dt = { files: [file('c.txt', 'text/plain')] } as unknown as DataTransfer
    expect(imageFilesFrom(dt)).toEqual([])
  })

  it('falls back to items (file kind) when files is empty', () => {
    const png = file('p.png', 'image/png')
    const dt = {
      files: [],
      items: [
        { kind: 'string', type: 'text/plain', getAsFile: () => null },
        { kind: 'file', type: 'image/png', getAsFile: () => png },
      ],
    } as unknown as DataTransfer
    expect(imageFilesFrom(dt)).toEqual([png])
  })

  it('prefers files over items so the same paste is not inserted twice', () => {
    const png = file('p.png', 'image/png')
    const dt = {
      files: [png],
      items: [{ kind: 'file', type: 'image/png', getAsFile: () => png }],
    } as unknown as DataTransfer
    expect(imageFilesFrom(dt)).toEqual([png])
  })
})

describe('fileToDataURL', () => {
  it('reads a file into a base64 data URI carrying its MIME type', async () => {
    const result = await fileToDataURL(file('hello.txt', 'text/plain', 'hello'))
    expect(result).toMatch(/^data:text\/plain;base64,/)
    // base64 payload가 원본 내용으로 디코드되는지 확인.
    const b64 = result.split(',')[1]
    expect(atob(b64)).toBe('hello')
  })

  it('preserves an image MIME type', async () => {
    const result = await fileToDataURL(file('x.png', 'image/png', 'PNGDATA'))
    expect(result.startsWith('data:image/png;base64,')).toBe(true)
  })
})

describe('MAX_IMAGE_BYTES', () => {
  it('is a sane positive limit (10MB)', () => {
    expect(MAX_IMAGE_BYTES).toBe(10 * 1024 * 1024)
    expect(MAX_IMAGE_BYTES).toBeGreaterThan(0)
  })
})
