import { test, expect } from './fixtures'

const GUTTER = { preview: '#annotation-gutter', source: '#raw-annotation-gutter' }

const comment = (replies: unknown[]) => ({
  id: 'c1', kind: 'comment', source: 'agent', author: 'agent', comment: 'Why this?',
  context_before: 'Natural ', target: 'wine', created: '2026-01-01T00:00:00Z', resolved: false,
  ...(replies.length ? { replies } : {}),
})
const reply = { id: 'r1', author: 'agent', source: 'agent', body: 'Agent follow-up', created: '2026-01-02T00:00:00Z' }

for (const mode of ['preview', 'source'] as const) {
  test(`agent reply to an existing comment shows up live (${mode})`, async ({ page, request }) => {
    const put = (replies: unknown[]) =>
      request.put('/api/folio', { data: { version: 1, annotations: [comment(replies)] } })
    await put([])
    await page.goto('/')
    await page.waitForSelector('.cm-content')
    if (mode === 'preview') await page.click('#view-toggle-btn')
    if (!(await page.locator('#app').evaluate(el => el.classList.contains('gutter-open')))) await page.click('#toggle-gutter-btn')
    await expect(page.locator(`${GUTTER[mode]} .ann-card`)).toHaveCount(1)
    await put([reply])
    await expect(page.locator(`${GUTTER[mode]} .ann-card`)).toContainText('Agent follow-up')
  })
}
