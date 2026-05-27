import { EventEmitter } from './EventEmitter'

export type PopoverTab = 'stats' | 'toc'

/**
 * 모든 UI 일시 상태의 단일 source of truth.
 * View들은 자체 상태를 들지 않고 이 객체만 구독해 그린다.
 */
export class UIState extends EventEmitter {
  private _infoPopoverOpen = false
  private _filenamePopoverOpen = false
  private _stylePopoverOpen = false
  private _activeTab: PopoverTab = 'stats'
  private _collapsedTocGroups = new Set<number>()

  get infoPopoverOpen(): boolean { return this._infoPopoverOpen }
  get filenamePopoverOpen(): boolean { return this._filenamePopoverOpen }
  get stylePopoverOpen(): boolean { return this._stylePopoverOpen }
  get activeTab(): PopoverTab { return this._activeTab }
  isTocGroupCollapsed(idx: number): boolean { return this._collapsedTocGroups.has(idx) }

  toggleInfoPopover(): void {
    // 다른 popover가 열려있으면 닫고 이것만 toggle (mutually exclusive)
    this._filenamePopoverOpen = false
    this._stylePopoverOpen = false
    this._infoPopoverOpen = !this._infoPopoverOpen
    this.emit('changed')
  }

  closeInfoPopover(): void {
    if (!this._infoPopoverOpen) return
    this._infoPopoverOpen = false
    this.emit('changed')
  }

  toggleFilenamePopover(): void {
    this._infoPopoverOpen = false
    this._stylePopoverOpen = false
    this._filenamePopoverOpen = !this._filenamePopoverOpen
    this.emit('changed')
  }

  closeFilenamePopover(): void {
    if (!this._filenamePopoverOpen) return
    this._filenamePopoverOpen = false
    this.emit('changed')
  }

  toggleStylePopover(): void {
    this._infoPopoverOpen = false
    this._filenamePopoverOpen = false
    this._stylePopoverOpen = !this._stylePopoverOpen
    this.emit('changed')
  }

  closeStylePopover(): void {
    if (!this._stylePopoverOpen) return
    this._stylePopoverOpen = false
    this.emit('changed')
  }

  setActiveTab(tab: PopoverTab): void {
    if (this._activeTab === tab) return
    this._activeTab = tab
    this.emit('changed')
  }

  toggleTocGroup(idx: number): void {
    if (this._collapsedTocGroups.has(idx)) this._collapsedTocGroups.delete(idx)
    else this._collapsedTocGroups.add(idx)
    this.emit('changed')
  }
}
