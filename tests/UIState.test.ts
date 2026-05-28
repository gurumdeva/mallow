import { describe, it, expect, vi } from 'vitest'
import { UIState } from '../src/domain/UIState.ts'

describe('UIState — initial state', () => {
  it('starts with all popovers closed and the stats tab active', () => {
    const ui = new UIState()
    expect(ui.infoPopoverOpen).toBe(false)
    expect(ui.filenamePopoverOpen).toBe(false)
    expect(ui.stylePopoverOpen).toBe(false)
    expect(ui.activeTab).toBe('stats')
    expect(ui.isTocGroupCollapsed(0)).toBe(false)
  })
})

describe('UIState — popover toggles', () => {
  it('toggleInfoPopover flips the info popover', () => {
    const ui = new UIState()
    ui.toggleInfoPopover()
    expect(ui.infoPopoverOpen).toBe(true)
    ui.toggleInfoPopover()
    expect(ui.infoPopoverOpen).toBe(false)
  })

  it('toggleFilenamePopover flips the filename popover', () => {
    const ui = new UIState()
    ui.toggleFilenamePopover()
    expect(ui.filenamePopoverOpen).toBe(true)
    ui.toggleFilenamePopover()
    expect(ui.filenamePopoverOpen).toBe(false)
  })

  it('toggleStylePopover flips the style popover', () => {
    const ui = new UIState()
    ui.toggleStylePopover()
    expect(ui.stylePopoverOpen).toBe(true)
    ui.toggleStylePopover()
    expect(ui.stylePopoverOpen).toBe(false)
  })
})

describe('UIState — popovers are mutually exclusive', () => {
  it('opening info closes filename and style', () => {
    const ui = new UIState()
    ui.toggleFilenamePopover() // open filename
    ui.toggleStylePopover() // open style (closes filename)
    expect(ui.stylePopoverOpen).toBe(true)
    ui.toggleInfoPopover() // open info (closes the rest)
    expect(ui.infoPopoverOpen).toBe(true)
    expect(ui.filenamePopoverOpen).toBe(false)
    expect(ui.stylePopoverOpen).toBe(false)
  })

  it('opening filename closes info and style', () => {
    const ui = new UIState()
    ui.toggleInfoPopover()
    ui.toggleFilenamePopover()
    expect(ui.filenamePopoverOpen).toBe(true)
    expect(ui.infoPopoverOpen).toBe(false)
    expect(ui.stylePopoverOpen).toBe(false)
  })

  it('opening style closes info and filename', () => {
    const ui = new UIState()
    ui.toggleInfoPopover()
    ui.toggleStylePopover()
    expect(ui.stylePopoverOpen).toBe(true)
    expect(ui.infoPopoverOpen).toBe(false)
    expect(ui.filenamePopoverOpen).toBe(false)
  })

  it('at most one popover is open at any time across a sequence of toggles', () => {
    const ui = new UIState()
    const openCount = () =>
      Number(ui.infoPopoverOpen) + Number(ui.filenamePopoverOpen) + Number(ui.stylePopoverOpen)
    ui.toggleInfoPopover()
    expect(openCount()).toBe(1)
    ui.toggleFilenamePopover()
    expect(openCount()).toBe(1)
    ui.toggleStylePopover()
    expect(openCount()).toBe(1)
    ui.toggleStylePopover() // close
    expect(openCount()).toBe(0)
  })
})

describe('UIState — close is idempotent', () => {
  it('closeInfoPopover does nothing (and does not emit) when already closed', () => {
    const ui = new UIState()
    const listener = vi.fn()
    ui.on('changed', listener)
    ui.closeInfoPopover()
    expect(ui.infoPopoverOpen).toBe(false)
    expect(listener).not.toHaveBeenCalled()
  })

  it('closeInfoPopover closes an open info popover and emits once', () => {
    const ui = new UIState()
    ui.toggleInfoPopover()
    const listener = vi.fn()
    ui.on('changed', listener)
    ui.closeInfoPopover()
    expect(ui.infoPopoverOpen).toBe(false)
    expect(listener).toHaveBeenCalledTimes(1)
    // 두 번째 close 는 무시된다.
    ui.closeInfoPopover()
    expect(listener).toHaveBeenCalledTimes(1)
  })

  it('closeFilenamePopover is idempotent', () => {
    const ui = new UIState()
    const listener = vi.fn()
    ui.on('changed', listener)
    ui.closeFilenamePopover()
    expect(listener).not.toHaveBeenCalled()
  })

  it('closeStylePopover is idempotent', () => {
    const ui = new UIState()
    const listener = vi.fn()
    ui.on('changed', listener)
    ui.closeStylePopover()
    expect(listener).not.toHaveBeenCalled()
  })
})

describe('UIState — setActiveTab', () => {
  it('changes the active tab and emits', () => {
    const ui = new UIState()
    const listener = vi.fn()
    ui.on('changed', listener)
    ui.setActiveTab('toc')
    expect(ui.activeTab).toBe('toc')
    expect(listener).toHaveBeenCalledTimes(1)
  })

  it('is a no-op (no emit) when the tab is already active', () => {
    const ui = new UIState()
    const listener = vi.fn()
    ui.on('changed', listener)
    ui.setActiveTab('stats') // already stats
    expect(ui.activeTab).toBe('stats')
    expect(listener).not.toHaveBeenCalled()
  })

  it('can switch back and forth', () => {
    const ui = new UIState()
    ui.setActiveTab('toc')
    ui.setActiveTab('stats')
    expect(ui.activeTab).toBe('stats')
  })
})

describe('UIState — toggleTocGroup', () => {
  it('collapses a group on first toggle and expands on second', () => {
    const ui = new UIState()
    expect(ui.isTocGroupCollapsed(2)).toBe(false)
    ui.toggleTocGroup(2)
    expect(ui.isTocGroupCollapsed(2)).toBe(true)
    ui.toggleTocGroup(2)
    expect(ui.isTocGroupCollapsed(2)).toBe(false)
  })

  it('tracks collapsed state per group index independently', () => {
    const ui = new UIState()
    ui.toggleTocGroup(0)
    ui.toggleTocGroup(5)
    expect(ui.isTocGroupCollapsed(0)).toBe(true)
    expect(ui.isTocGroupCollapsed(5)).toBe(true)
    expect(ui.isTocGroupCollapsed(1)).toBe(false)
  })

  it('emits changed on every toggle', () => {
    const ui = new UIState()
    const listener = vi.fn()
    ui.on('changed', listener)
    ui.toggleTocGroup(0)
    ui.toggleTocGroup(0)
    expect(listener).toHaveBeenCalledTimes(2)
  })
})

describe('UIState — change emissions on toggles', () => {
  it('every popover toggle emits changed', () => {
    const ui = new UIState()
    const listener = vi.fn()
    ui.on('changed', listener)
    ui.toggleInfoPopover()
    ui.toggleFilenamePopover()
    ui.toggleStylePopover()
    expect(listener).toHaveBeenCalledTimes(3)
  })
})
