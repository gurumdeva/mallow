export type Stats = {
  words: number
  characters: number
  paragraphs: number
  readMinutes: number
}

/**
 * 마크다운 문자열로부터 통계를 계산하는 순수 함수 클래스.
 * 외부 상태 의존 없음.
 */
export class StatsCalculator {
  calculate(markdown: string): Stats {
    const text = markdown.trim()
    const characters = text.length
    if (characters === 0) {
      return { words: 0, characters: 0, paragraphs: 0, readMinutes: 0 }
    }
    // 공백 기준 어절(한국어) / 단어(영어)
    const words = text.split(/\s+/).filter(Boolean).length
    const paragraphs = text.split(/\n{2,}/).filter((p) => p.trim()).length
    // 한국어 평균 분당 500자 가정
    const readMinutes = Math.max(1, Math.ceil(characters / 500))
    return { words, characters, paragraphs, readMinutes }
  }
}
