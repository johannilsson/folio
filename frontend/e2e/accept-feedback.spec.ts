import { test, expect } from './fixtures'
import type { Page } from '@playwright/test'

// Served by the second webServer in playwright.config.ts (long.md has 150 paragraphs).
test.use({ baseURL: 'http://127.0.0.1:7392' })

const MODES = {
  preview: { wrapper: '#editor-wrapper', content: '#editor-tiptap', gutter: '#annotation-gutter' },
  source: { wrapper: '#raw-editor-wrapper', content: '.cm-content', gutter: '#raw-annotation-gutter' },
} as const

// Accepting edits the file for good and the server is shared with other tests, so each
// use takes the first untouched paragraph (this also survives a worker restart or retry).
async function setup(page: Page, request: any, mode: keyof typeof MODES, kind: 'replace' | 'delete') {
  const m = MODES[mode]
  const list: Array<{ id: string; name: string }> = await (await request.get('/api/files')).json()
  const long = list.find(f => f.name === 'long.md')!
  const text = await (await request.get(`/api/file?file=${long.id}`)).text()
  const n = Array.from({ length: 60 }, (_, i) => 80 + i)
    .find(i => text.includes(`Paragraph ${i - 1} of the long`) && text.includes(`Paragraph ${i} of the long`))!
  const target = `Paragraph ${n} of`
  await request.put(`/api/folio?file=${long.id}`, {
    data: JSON.stringify({
      version: 1,
      annotations: [{
        id: `ann_fb${n}`, kind, source: 'agent', author: 'agent',
        context_before: `Paragraph ${n - 1} of the long file.`, target,
        ...(kind === 'replace' ? { replacement: `Section ${n} of` } : {}),
        comment: 'tidy', created: '2026-01-01T00:00:00Z', resolved: false,
      }],
    }),
  })
  await page.goto(`/?file=${long.id}`)
  await page.waitForSelector('.cm-content')
  if (mode === 'preview') {
    await page.click('#view-toggle-btn')
    await page.waitForSelector('#editor-tiptap .ProseMirror', { state: 'visible' })
  }
  if (!(await page.locator('#app').evaluate(el => el.classList.contains('gutter-open')))) await page.click('#toggle-gutter-btn')
  const card = page.locator(`${m.gutter} .ann-card`)
  await expect(card).toHaveCount(1)
  await expect.poll(() => page.locator(m.wrapper).evaluate(el => el.scrollHeight - el.clientHeight)).toBeGreaterThan(1600)
  await page.locator(m.wrapper).evaluate((el, f) => { el.scrollTop = el.scrollHeight * f - el.clientHeight / 2 }, n / 150)
  await expect(card).toBeInViewport()
  return { m, n, card }
}

for (const mode of ['preview', 'source'] as const) {
  test(`accepting keeps the page where it was (${mode})`, async ({ page, request }) => {
    const { m, n, card } = await setup(page, request, mode, 'replace')
    const scrollTop = () => page.locator(m.wrapper).evaluate(el => el.scrollTop)
    const textY = (needle: string) => page.locator(m.content).getByText(needle).first().evaluate(el => el.getBoundingClientRect().top)
    await expect.poll(scrollTop).toBeGreaterThan(500)
    const before = await scrollTop()
    expect(before).toBeGreaterThan(500)
    const yBefore = await textY(`Paragraph ${n - 1} of`)

    await card.hover()
    await card.getByTitle('Accept').click()
    await expect(page.locator(m.content)).toContainText(`Section ${n} of`)
    await page.waitForTimeout(500)

    expect(Math.abs((await scrollTop()) - before)).toBeLessThan(5)
    expect(Math.abs((await textY(`Paragraph ${n - 1} of`)) - yBefore)).toBeLessThan(5)
  })
}

for (const mode of ['preview', 'source'] as const) {
  test(`accepting shows a toast and flashes the new text (${mode})`, async ({ page, request }) => {
    const { m, n, card } = await setup(page, request, mode, 'replace')
    await card.hover()
    await card.getByTitle('Accept').click()
    await expect(page.locator('#folio-toast')).toBeVisible()
    await expect(page.locator('#folio-toast')).toContainText('Accepted replace')
    // Centred on the text, so it never sits over the comment pane.
    const toast = (await page.locator('#folio-toast').boundingBox())!
    const gutter = (await page.locator(m.gutter).boundingBox())!
    expect(toast.x + toast.width).toBeLessThan(gutter.x)
    await expect(page.locator(m.content)).toContainText(`Section ${n} of`)
    await page.waitForFunction(() => CSS.highlights.has('folio-flash'), null, { polling: 'raf' })
    await expect.poll(() => page.evaluate(() => CSS.highlights.has('folio-flash'))).toBe(false)
  })

  test(`removing shows a toast whose Undo brings the annotation back (${mode})`, async ({ page, request }) => {
    const { m, card } = await setup(page, request, mode, 'delete')
    await card.hover()
    await card.getByTitle('More').click()
    await card.getByText('Delete', { exact: true }).click()
    await expect(page.locator(`${m.gutter} .ann-card`)).toHaveCount(0)
    await expect(page.locator('#folio-toast')).toContainText('Rejected delete')
    await page.locator('#folio-toast button', { hasText: 'Undo' }).dispatchEvent('mousedown')
    await expect(page.locator(`${m.gutter} .ann-card`)).toHaveCount(1)
    await expect(page.locator('#folio-toast')).toBeHidden()
  })
}
