import { EventEmitter } from './EventEmitter'

/**
 * 현재 열려 있는 문서의 도메인 상태.
 * - 파일 경로/이름/저장 상태/마지막 수정 시각
 * - 변경 시 'changed' 이벤트 발행 (옵저버 패턴)
 */
export class Document extends EventEmitter {
  private _filePath: string | null = null
  private _filename = '새 문서.md'
  private _isModified = false
  private _lastModified = new Date()

  get filePath(): string | null { return this._filePath }
  get filename(): string { return this._filename }
  get isModified(): boolean { return this._isModified }
  get lastModified(): Date { return this._lastModified }

  /** 화면용 디스플레이 타이틀 (● prefix 포함) */
  get displayTitle(): string {
    return (this._isModified ? '● ' : '') + this._filename
  }

  setPath(path: string): void {
    this._filePath = path
    this._filename = path.split('/').pop() ?? this._filename
    this.emit('changed')
  }

  rename(name: string): void {
    const trimmed = name.trim()
    if (!trimmed) return
    this._filename = trimmed.endsWith('.md') ? trimmed : `${trimmed}.md`
    this.emit('changed')
  }

  resetToNew(): void {
    this._filePath = null
    this._filename = '새 문서.md'
    this._isModified = false
    this._lastModified = new Date()
    this.emit('changed')
  }

  markModified(): void {
    this._lastModified = new Date()
    this._isModified = true
    this.emit('changed')
  }

  markSaved(): void {
    if (!this._isModified) return
    this._isModified = false
    this.emit('changed')
  }
}
