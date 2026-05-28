import { describe, it, expect, vi } from 'vitest'
import { EventEmitter } from '../src/domain/EventEmitter.ts'

/**
 * emit() 은 protected 라 외부에서 직접 호출할 수 없다.
 * 테스트용 서브클래스로 public 프록시를 노출한다(앱 코드는 변경하지 않음).
 */
class TestEmitter extends EventEmitter {
  fire(event: string): void {
    this.emit(event)
  }
}

describe('EventEmitter', () => {
  it('invokes a registered listener on emit', () => {
    const em = new TestEmitter()
    const listener = vi.fn()
    em.on('changed', listener)
    em.fire('changed')
    expect(listener).toHaveBeenCalledTimes(1)
  })

  it('invokes all listeners registered for the same event', () => {
    const em = new TestEmitter()
    const a = vi.fn()
    const b = vi.fn()
    em.on('changed', a)
    em.on('changed', b)
    em.fire('changed')
    expect(a).toHaveBeenCalledTimes(1)
    expect(b).toHaveBeenCalledTimes(1)
  })

  it('does not invoke listeners registered for a different event', () => {
    const em = new TestEmitter()
    const other = vi.fn()
    em.on('other', other)
    em.fire('changed')
    expect(other).not.toHaveBeenCalled()
  })

  it('stops invoking a listener after off()', () => {
    const em = new TestEmitter()
    const listener = vi.fn()
    em.on('changed', listener)
    em.off('changed', listener)
    em.fire('changed')
    expect(listener).not.toHaveBeenCalled()
  })

  it('off() only removes the specified listener', () => {
    const em = new TestEmitter()
    const keep = vi.fn()
    const remove = vi.fn()
    em.on('changed', keep)
    em.on('changed', remove)
    em.off('changed', remove)
    em.fire('changed')
    expect(keep).toHaveBeenCalledTimes(1)
    expect(remove).not.toHaveBeenCalled()
  })

  it('deduplicates the same listener reference (Set semantics)', () => {
    const em = new TestEmitter()
    const listener = vi.fn()
    em.on('changed', listener)
    em.on('changed', listener)
    em.fire('changed')
    expect(listener).toHaveBeenCalledTimes(1)
  })

  it('emitting an event with no listeners is a no-op (does not throw)', () => {
    const em = new TestEmitter()
    expect(() => em.fire('nothing-here')).not.toThrow()
  })

  it('off() for an unknown event/listener is safe', () => {
    const em = new TestEmitter()
    expect(() => em.off('never-registered', () => {})).not.toThrow()
  })

  it('re-registering after off() works again', () => {
    const em = new TestEmitter()
    const listener = vi.fn()
    em.on('changed', listener)
    em.off('changed', listener)
    em.on('changed', listener)
    em.fire('changed')
    expect(listener).toHaveBeenCalledTimes(1)
  })
})
