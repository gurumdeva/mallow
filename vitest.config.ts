import { defineConfig } from 'vitest/config'

/**
 * Vitest 설정.
 *
 * 테스트 파일은 Vitest 함수(describe/it/expect)를 명시적으로 import 한다.
 * `globals: true` 를 켜지 않는 이유: 그러면 tsconfig.json 의 `types` 에
 * "vitest/globals" 를 추가해야 하고, 그 변경은 `npm run build`(tsc) 까지
 * 영향을 주기 때문이다. 명시적 import 방식은 앱 빌드 설정을 건드리지 않는다.
 *
 * environment: 'jsdom' — TocExtractor 가 `document.querySelectorAll('.ProseMirror …')`
 * 를 사용하므로 DOM 이 필요하다.
 */
export default defineConfig({
  test: {
    environment: 'jsdom',
    include: ['tests/**/*.test.ts'],
  },
})
