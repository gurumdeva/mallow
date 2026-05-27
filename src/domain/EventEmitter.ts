export type Listener = () => void

/**
 * 최소한의 옵저버 패턴 인프라.
 * Document와 UIState가 상속해 'changed' 이벤트를 발행한다.
 */
export class EventEmitter {
  private listeners = new Map<string, Set<Listener>>()

  on(event: string, listener: Listener): void {
    let set = this.listeners.get(event)
    if (!set) {
      set = new Set()
      this.listeners.set(event, set)
    }
    set.add(listener)
  }

  off(event: string, listener: Listener): void {
    this.listeners.get(event)?.delete(listener)
  }

  protected emit(event: string): void {
    this.listeners.get(event)?.forEach((l) => l())
  }
}
