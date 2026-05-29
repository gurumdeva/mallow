import { describe, it, expect, vi, beforeEach } from 'vitest'
import { Document } from '../src/domain/Document.ts'
import { setLocale } from '../src/i18n/index.ts'

beforeEach(() => {
  // Document 의 기본 파일명은 t('doc.untitled') 로 결정되므로 로케일을 고정한다.
  setLocale('en')
})

describe('Document.normalizeFilename', () => {
  it('appends .md to a plain base name', () => {
    expect(Document.normalizeFilename('notes')).toBe('notes.md')
  })

  it('trims surrounding whitespace', () => {
    expect(Document.normalizeFilename('  notes  ')).toBe('notes.md')
  })

  it('strips a single trailing .md before re-appending', () => {
    expect(Document.normalizeFilename('notes.md')).toBe('notes.md')
  })

  it('strips trailing .md case-insensitively', () => {
    expect(Document.normalizeFilename('notes.MD')).toBe('notes.md')
    expect(Document.normalizeFilename('notes.Md')).toBe('notes.md')
  })

  it('trims again after stripping .md', () => {
    expect(Document.normalizeFilename('  notes  .md')).toBe('notes.md')
  })

  it('returns null for an empty string', () => {
    expect(Document.normalizeFilename('')).toBeNull()
  })

  it('returns null for whitespace only', () => {
    expect(Document.normalizeFilename('   ')).toBeNull()
  })

  it('returns null when only ".md" is provided (empty base)', () => {
    expect(Document.normalizeFilename('.md')).toBeNull()
    expect(Document.normalizeFilename('  .md  ')).toBeNull()
  })

  it('keeps a leading dot when the base is more than just .md', () => {
    // ".env" 는 ".md" 로 끝나지 않으므로 base ".env" 가 유지된다.
    expect(Document.normalizeFilename('.env')).toBe('.env.md')
  })

  it('only strips the final .md, keeping interior dots', () => {
    expect(Document.normalizeFilename('a.b.md')).toBe('a.b.md')
    expect(Document.normalizeFilename('release.notes')).toBe('release.notes.md')
  })

  it('rejects names containing path separators (no folder escape)', () => {
    // 디스크 rename 경로가 "폴더 + 이름"으로 조립되므로 분리자/상위경로는 폴더 밖으로
    // 나가거나 다른 파일을 덮어쓸 수 있어 무효 처리한다.
    expect(Document.normalizeFilename('../evil')).toBeNull()
    expect(Document.normalizeFilename('../../etc/passwd')).toBeNull()
    expect(Document.normalizeFilename('sub/dir/note')).toBeNull()
    expect(Document.normalizeFilename('a\\b')).toBeNull()
    expect(Document.normalizeFilename('..')).toBeNull()
    expect(Document.normalizeFilename('.')).toBeNull()
    expect(Document.normalizeFilename('/abs/path')).toBeNull()
  })

  it('still allows ordinary names with dots and spaces', () => {
    expect(Document.normalizeFilename('my notes v2')).toBe('my notes v2.md')
    expect(Document.normalizeFilename('2026-05-29 회고')).toBe('2026-05-29 회고.md')
  })
})

describe('Document defaults', () => {
  it('starts untitled, unmodified, with no path, and pristine', () => {
    const doc = new Document()
    expect(doc.filePath).toBeNull()
    expect(doc.filename).toBe('Untitled.md')
    expect(doc.isModified).toBe(false)
    expect(doc.isPristine).toBe(true)
    expect(doc.lastModified).toBeInstanceOf(Date)
  })
})

describe('Document.displayTitle', () => {
  it('has no prefix when unmodified', () => {
    const doc = new Document()
    expect(doc.displayTitle).toBe('Untitled.md')
  })

  it('prepends "● " only when modified', () => {
    const doc = new Document()
    doc.markModified()
    expect(doc.displayTitle).toBe('● Untitled.md')
  })

  it('drops the prefix again after saving', () => {
    const doc = new Document()
    doc.markModified()
    doc.markSaved()
    expect(doc.displayTitle).toBe('Untitled.md')
  })
})

describe('Document.rename', () => {
  it('normalizes and applies a valid name, emitting changed', () => {
    const doc = new Document()
    const listener = vi.fn()
    doc.on('changed', listener)
    doc.rename('my notes')
    expect(doc.filename).toBe('my notes.md')
    expect(listener).toHaveBeenCalledTimes(1)
  })

  it('ignores an invalid (empty) name and does not emit', () => {
    const doc = new Document()
    const listener = vi.fn()
    doc.on('changed', listener)
    doc.rename('   ')
    expect(doc.filename).toBe('Untitled.md') // unchanged
    expect(listener).not.toHaveBeenCalled()
  })

  it('ignores a ".md"-only name', () => {
    const doc = new Document()
    doc.rename('.md')
    expect(doc.filename).toBe('Untitled.md')
  })
})

describe('Document.setPath', () => {
  it('sets the path and derives the filename from the basename', () => {
    const doc = new Document()
    doc.setPath('/Users/me/Documents/report.md')
    expect(doc.filePath).toBe('/Users/me/Documents/report.md')
    expect(doc.filename).toBe('report.md')
  })

  it('emits changed when the path is set', () => {
    const doc = new Document()
    const listener = vi.fn()
    doc.on('changed', listener)
    doc.setPath('/tmp/a.md')
    expect(listener).toHaveBeenCalledTimes(1)
  })

  it('makes the document no longer pristine (path is now set)', () => {
    const doc = new Document()
    doc.setPath('/tmp/a.md')
    expect(doc.isPristine).toBe(false)
  })
})

describe('Document.markModified / markSaved', () => {
  it('markModified sets isModified, updates lastModified, and emits', () => {
    const doc = new Document()
    const before = doc.lastModified.getTime()
    const listener = vi.fn()
    doc.on('changed', listener)
    vi.useFakeTimers()
    vi.setSystemTime(before + 1000)
    doc.markModified()
    vi.useRealTimers()
    expect(doc.isModified).toBe(true)
    expect(doc.lastModified.getTime()).toBeGreaterThanOrEqual(before)
    expect(listener).toHaveBeenCalledTimes(1)
  })

  it('markSaved clears isModified and emits when there were changes', () => {
    const doc = new Document()
    doc.markModified()
    const listener = vi.fn()
    doc.on('changed', listener)
    doc.markSaved()
    expect(doc.isModified).toBe(false)
    expect(listener).toHaveBeenCalledTimes(1)
  })

  it('markSaved is a no-op (no emit) when already unmodified', () => {
    const doc = new Document()
    const listener = vi.fn()
    doc.on('changed', listener)
    doc.markSaved()
    expect(doc.isModified).toBe(false)
    expect(listener).not.toHaveBeenCalled()
  })

  it('a modified document with no path is not pristine', () => {
    const doc = new Document()
    doc.markModified()
    expect(doc.isPristine).toBe(false)
  })
})
