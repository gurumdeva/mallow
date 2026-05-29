// payload는 선택적. 'change'/'changed' 같은 기존 이벤트는 인자 없이 발행되고
// 리스너도 무시하므로, payload 추가는 하위 호환이다(이미지 에러처럼 사유를 전달할 때만 사용).
export type Listener = (payload?: unknown) => void

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

  protected emit(event: string, payload?: unknown): void {
    this.listeners.get(event)?.forEach((l) => l(payload))
  }
}
