import en from './locales/en.json'
import ko from './locales/ko.json'
import ja from './locales/ja.json'

export type Lang = 'en' | 'ko' | 'ja'

/**
 * en.json의 모든 leaf 값을 string으로 넓힌 타입. ko 리소스가 en과 "같은 키 집합"을
 * 갖도록 컴파일 타임에 강제하되, 값(번역문)은 자유롭게 다를 수 있게 한다.
 * (리터럴 타입 "File" vs "파일" 불일치로 인한 오탐을 막는다.)
 */
type Stringify<T> = {
  [K in keyof T]: T[K] extends string ? string : Stringify<T[K]>
}

/**
 * 점(.)으로 이어진 모든 leaf 경로의 유니온. t()에 키 자동완성과 오타 시
 * 컴파일 에러를 제공한다. 예: "menu.file" | "style.tip.bold" | ...
 */
type Leaves<T> = T extends string
  ? ''
  : {
      [K in keyof T & string]: Leaves<T[K]> extends '' ? K : `${K}.${Leaves<T[K]>}`
    }[keyof T & string]

export type TKey = Leaves<typeof en>

// en을 기준 형태로 삼고 ko·ja가 동일 키를 갖도록 강제한다(키 누락 시 빌드 실패).
const resources: Record<Lang, Stringify<typeof en>> = { en, ko, ja }

let current: Lang = 'en'

/**
 * OS/브라우저 locale 문자열("ko-KR", "ja-JP", "en-US" 등)을 지원 언어로 정규화한다.
 * 한국어→ko, 일본어→ja, 그 외에는 모두 en으로 폴백한다(기기 언어 단일 결정).
 */
export function resolveLang(raw: string | null | undefined): Lang {
  const lower = raw?.toLowerCase() ?? ''
  if (lower.startsWith('ko')) return 'ko'
  if (lower.startsWith('ja')) return 'ja'
  return 'en'
}

export function setLocale(lang: Lang): void {
  current = lang
}

export function getLocale(): Lang {
  return current
}

/**
 * "{name}" 형태의 자리표시자를 params 값으로 치환한다.
 * params에 없는 키는 원형을 그대로 남겨 둔다(누락을 눈에 띄게 하기 위함).
 */
function interpolate(template: string, params?: Record<string, string | number>): string {
  if (!params) return template
  return template.replace(/\{(\w+)\}/g, (whole, key: string) =>
    key in params ? String(params[key]) : whole,
  )
}

/**
 * lang 리소스에서 점 경로로 문자열을 찾는다.
 * 없으면 en으로 폴백하고, 그래도 없으면 키 자체를 반환한다(절대 깨지지 않게).
 */
function resolve(lang: Lang, key: string): string {
  const walk = (root: unknown): string | undefined => {
    let node: unknown = root
    for (const part of key.split('.')) {
      if (node !== null && typeof node === 'object' && part in node) {
        node = (node as Record<string, unknown>)[part]
      } else {
        return undefined
      }
    }
    return typeof node === 'string' ? node : undefined
  }
  return walk(resources[lang]) ?? walk(resources.en) ?? key
}

/** 현재 언어로 키를 번역하고 자리표시자를 치환해 반환한다. */
export function t(key: TKey, params?: Record<string, string | number>): string {
  return interpolate(resolve(current, key), params)
}
