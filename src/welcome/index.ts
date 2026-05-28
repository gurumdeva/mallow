import en from './en.md?raw'
import ko from './ko.md?raw'
import ja from './ja.md?raw'
import type { Lang } from '../i18n'

/** 첫 실행 시 보여줄 환영 문서(기기 언어 기준). */
export function welcomeDoc(lang: Lang): string {
  if (lang === 'ko') return ko
  if (lang === 'ja') return ja
  return en
}
