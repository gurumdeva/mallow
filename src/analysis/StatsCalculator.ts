import type { Lang } from '../i18n'

export type Stats = {
  words: number
  characters: number
  paragraphs: number
  readMinutes: number
}

/**
 * 마크다운 문자열로부터 통계를 계산하는 순수 함수 클래스. 외부 상태 의존 없음.
 * 언어(lang)를 받아 단어 분절·읽기 시간 계산을 현지화한다.
 */
export class StatsCalculator {
  /**
   * @param lang 단어 분절 로캘 + 읽기 속도 기준 결정. 미지정 시 'en'.
   */
  calculate(markdown: string, lang: Lang = 'en'): Stats {
    // 이미지 마크다운 ![alt](url) 은 모든 통계(글자/단어/문단/읽기시간)에서 제외한다.
    // 특히 붙여넣은 이미지의 base64 data URI는 매우 긴 문자열이라, 포함하면 글자 수·읽기
    // 시간이 비정상적으로 부풀려지고(이미지 한 장에 "2594분"), 이미지만 있는 줄이 문단으로
    // 잘못 세이기도 한다. URL 안에 괄호가 1단계 중첩된 경우(예: 위키백과 Foo_(bar))도
    // 통째로 제거하도록 균형 괄호 패턴을 쓴다. 줄바꿈은 보존돼 문단 구조는 유지된다.
    const withoutImages = markdown.replace(/!\[[^\]]*\]\(([^()]*(?:\([^()]*\)[^()]*)*)\)/g, '')
    const text = withoutImages.trim()
    const characters = text.length
    if (characters === 0) {
      return { words: 0, characters: 0, paragraphs: 0, readMinutes: 0 }
    }

    const words = countWords(text, lang)
    // 문단도 이미지 제거 후의 텍스트로 센다(이미지만 있는 줄을 산문 문단으로 세지 않도록).
    const paragraphs = countParagraphs(withoutImages)

    // 읽기 시간: 라틴 문자권(en)은 단어 기준(분당 200단어), CJK(ko/ja)는 글자 기준
    // (분당 500자)이 더 현실적이다. 기존엔 모든 언어에 500자/분을 적용해 영어 문서의
    // 읽기 시간이 과대평가됐다.
    const readMinutes =
      lang === 'en'
        ? Math.max(1, Math.ceil(words / 200))
        : Math.max(1, Math.ceil(characters / 500))

    return { words, characters, paragraphs, readMinutes }
  }
}

/**
 * 단어 수. Intl.Segmenter(granularity:'word')로 분절해 단어형 세그먼트만 센다.
 * 공백을 쓰지 않는 일본어/중국어도 사전 기반으로 올바르게 분절된다
 * (기존의 공백 split은 "今日はいい天気" 같은 문장을 1단어로 셌다).
 * Segmenter 미지원 환경에서는 공백 기준으로 폴백한다.
 */
function countWords(text: string, lang: Lang): number {
  try {
    const seg = new Intl.Segmenter(lang, { granularity: 'word' })
    let n = 0
    // for-of 동치: const it = seg.segment(text); for (const s of it) if (s.isWordLike) n++
    for (const s of seg.segment(text)) {
      if (s.isWordLike) n++
    }
    return n
  } catch {
    // Intl.Segmenter 미지원 → 공백 기준 어절/단어 수로 폴백
    return text.split(/\s+/).filter(Boolean).length
  }
}

/**
 * 문단 수. 빈 줄로 구분된 블록 중 "산문 문단"만 센다. 제목(#), 목록 항목,
 * 코드 블록, 구분선(---), 인용(>)은 문단으로 세지 않는다(기존엔 전부 셌다).
 */
function countParagraphs(markdown: string): number {
  // 1) 펜스 코드 블록(``` … ```)을 통째로 제거 — 코드 줄이 문단으로 세이지 않도록.
  const withoutCode = markdown.replace(/```[\s\S]*?```/g, '\n\n')
  // 2) 빈 줄(2개 이상 개행)로 블록 분리.
  const blocks = withoutCode.split(/\n{2,}/)
  let count = 0
  for (const block of blocks) {
    const lines = block.split('\n').filter((l) => l.trim().length > 0)
    if (lines.length === 0) continue // 공백만 있는 블록
    // 블록에 "구조적 마커가 아닌 산문 줄"이 하나라도 있으면 문단으로 센다.
    const hasProse = lines.some((line) => !isStructuralLine(line))
    if (hasProse) count++
  }
  return count
}

/** 제목/구분선/목록/인용처럼 산문이 아닌 구조적 줄인지. */
function isStructuralLine(line: string): boolean {
  const s = line.trim()
  return (
    /^#{1,6}\s/.test(s) || // 제목
    /^(-{3,}|\*{3,}|_{3,})$/.test(s) || // 구분선(hr)
    /^([-*+]|\d+[.)])\s/.test(s) || // 목록 항목
    /^>/.test(s) // 인용
  )
}
