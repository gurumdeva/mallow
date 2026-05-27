type ToastKind = 'error' | 'info'

/**
 * 간단한 toast 알림 서비스.
 * 우측 상단에 잠시 떴다가 자동으로 사라지는 메시지. 에러 발생 시 사용자에게
 * silent fail 대신 알려주기 위한 인프라.
 *
 * - container는 body에 한 번만 부착 (싱글톤처럼 사용)
 * - 자체 상태 없음 — 각 toast는 transient한 DOM 노드로 생성/제거
 */
export class ToastService {
  private readonly container: HTMLDivElement

  constructor() {
    // 이미 만들어진 컨테이너가 있으면 재사용 (다중 인스턴스 안전성).
    const existing = document.getElementById('toast-container') as HTMLDivElement | null
    if (existing) {
      this.container = existing
    } else {
      this.container = document.createElement('div')
      this.container.id = 'toast-container'
      document.body.appendChild(this.container)
    }
  }

  error(message: string): void {
    this.show(message, 'error')
  }

  info(message: string): void {
    this.show(message, 'info')
  }

  private show(message: string, kind: ToastKind): void {
    const toast = document.createElement('div')
    toast.className = `toast toast-${kind}`
    toast.textContent = message
    this.container.appendChild(toast)

    // CSS transition을 위해 다음 frame에 visible 클래스 부여.
    requestAnimationFrame(() => toast.classList.add('toast-visible'))

    // 3.5초 후 fade out, 200ms 뒤 제거.
    window.setTimeout(() => {
      toast.classList.remove('toast-visible')
      window.setTimeout(() => toast.remove(), 200)
    }, 3500)
  }
}

/**
 * unknown 에러 객체를 사용자에게 보여줄 짧은 문자열로 변환.
 * 너무 길거나 stack trace를 그대로 보여주면 곤란하므로 message만 추출, 최대 200자.
 */
export function formatError(e: unknown, fallback = '알 수 없는 오류'): string {
  if (e == null) return fallback
  let msg = ''
  if (e instanceof Error) msg = e.message
  else if (typeof e === 'string') msg = e
  else {
    try { msg = JSON.stringify(e) } catch { msg = String(e) }
  }
  msg = msg.trim() || fallback
  return msg.length > 200 ? msg.slice(0, 200) + '…' : msg
}
