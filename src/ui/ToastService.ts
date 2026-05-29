import { t } from '../i18n'

type ToastKind = 'error' | 'info'

/**
 * 간단한 toast 알림 서비스.
 * 우측 상단에 잠시 떴다가 자동으로 사라지는 메시지. 에러 발생 시 사용자에게
 * silent fail 대신 알려주기 위한 인프라.
 *
 * - container는 body에 한 번만 부착 (싱글톤처럼 사용)
 * - 자체 상태 없음 — 각 toast는 transient한 DOM 노드로 생성/제거
 */
/** 현재 화면에 떠 있는 토스트 하나의 추적 정보(dedup/cap/타이머 관리용). */
type ActiveToast = {
  el: HTMLDivElement
  message: string
  kind: ToastKind
  timer: ReturnType<typeof setTimeout>
}

// 동시에 보일 수 있는 토스트 최대 개수. 초과하면 가장 오래된 것을 먼저 내린다(item 10).
const MAX_VISIBLE = 4
const DISMISS_MS = 3500
const FADE_MS = 200

export class ToastService {
  private readonly container: HTMLDivElement
  // 표시 중인 토스트 목록(오래된 → 최신). dedup 검사와 cap 적용에 쓴다.
  private readonly active: ActiveToast[] = []

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
    // 스크린리더가 메시지를 읽도록 live region으로 노출(item 9).
    this.container.setAttribute('role', 'status')
    this.container.setAttribute('aria-live', 'polite')
  }

  error(message: string): void {
    this.show(message, 'error')
  }

  info(message: string): void {
    this.show(message, 'info')
  }

  private show(message: string, kind: ToastKind): void {
    // 중복 제거(item 10): 같은 종류·문구가 이미 떠 있으면 새로 쌓지 않고 타이머만 갱신한다.
    const dup = this.active.find((a) => a.message === message && a.kind === kind)
    if (dup) {
      clearTimeout(dup.timer)
      dup.timer = window.setTimeout(() => this.dismiss(dup), DISMISS_MS)
      return
    }

    const toast = document.createElement('div')
    toast.className = `toast toast-${kind}`
    toast.textContent = message
    this.container.appendChild(toast)

    const entry: ActiveToast = {
      el: toast,
      message,
      kind,
      timer: window.setTimeout(() => this.dismiss(entry), DISMISS_MS),
    }
    this.active.push(entry)

    // 개수 상한 초과 시 가장 오래된 토스트부터 즉시 내린다(item 10).
    while (this.active.length > MAX_VISIBLE) {
      this.dismiss(this.active[0])
    }

    // CSS transition을 위해 다음 frame에 visible 클래스 부여.
    requestAnimationFrame(() => toast.classList.add('toast-visible'))
  }

  /** 토스트 하나를 fade out 후 DOM·추적 목록에서 제거. 중복 호출에 안전. */
  private dismiss(entry: ActiveToast): void {
    const i = this.active.indexOf(entry)
    if (i === -1) return // 이미 내려간 토스트
    this.active.splice(i, 1)
    clearTimeout(entry.timer)
    entry.el.classList.remove('toast-visible')
    window.setTimeout(() => entry.el.remove(), FADE_MS)
  }
}

/**
 * unknown 에러 객체를 사용자에게 보여줄 짧은 문자열로 변환.
 * 너무 길거나 stack trace를 그대로 보여주면 곤란하므로 message만 추출, 최대 200자.
 */
export function formatError(e: unknown, fallback = t('toast.unknownError')): string {
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
