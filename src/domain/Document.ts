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

  /**
   * "깨끗한 새 문서" 여부 — 경로가 없고(저장된 적 없음) 수정도 없는 상태.
   * 멀티 창에서 파일을 열 때 이 창을 재사용할지(true) 새 창을 띄울지(false) 판단에 쓴다.
   */
  get isPristine(): boolean {
    return this._filePath === null && !this._isModified
  }

  setPath(path: string): void {
    this._filePath = path
    this._filename = path.split('/').pop() ?? this._filename
    this.emit('changed')
  }

  /**
   * 파일명 정규화: 앞뒤 공백 제거 + base 이름이 있으면 '.md' 보장. base가 비면 null.
   * (".md"·공백만 입력 → null. rename과 디스크 rename 경로 계산에서 공용으로 쓴다.)
   */
  static normalizeFilename(name: string): string | null {
    let base = name.trim()
    if (base.toLowerCase().endsWith('.md')) base = base.slice(0, -3).trim()
    if (!base) return null
    return `${base}.md`
  }

  rename(name: string): void {
    const fn = Document.normalizeFilename(name)
    if (!fn) return
    this._filename = fn
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
