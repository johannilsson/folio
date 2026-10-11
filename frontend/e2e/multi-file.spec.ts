import { test, expect } from './fixtures'
import type { APIRequestContext, Page } from '@playwright/test'

// Served by the second webServer in playwright.config.ts: a/alpha.md and b/beta.md.
test.use({ baseURL: 'http://127.0.0.1:7392' })

interface FileSummary { id: string; name: string; group: string; pending: number }

async function files(request: APIRequestContext): Promise<Record<string, FileSummary>> {
  const list: FileSummary[] = await (await request.get('/api/files')).json()
  return Object.fromEntries(list.map(f => [f.name, f]))
}

function comment(id: string) {
  return {
    id, kind: 'comment', source: 'local', author: 'me', context_before: 'Orange wine gets its ',
    target: 'colour', comment: 'check spelling', created: '2026-01-01T00:00:00Z', resolved: false,
  }
}

async function setBetaAnnotations(request: APIRequestContext, count: number) {
  const { 'beta.md': beta } = await files(request)
  const annotations = Array.from({ length: count }, (_, i) => comment(`ann_e2e${i}`))
  await request.put(`/api/folio?file=${beta.id}`, { data: JSON.stringify({ version: 1, annotations }) })
}

const open = async (page: Page, id: string) => {
  await page.goto(`/?file=${id}`)
  await page.waitForSelector('.cm-content')
}

const openMenu = async (page: Page) => {
  await page.click('#title-pill')
  await expect(page.locator('#file-menu')).toBeVisible()
}

// Picks a file from the menu; a flag set on window beforehand proves no reload happened.
const pick = async (page: Page, name: string) => {
  await openMenu(page)
  await page.locator('#file-menu .fm-item', { hasText: name }).click()
}

test.afterEach(async ({ request }) => setBetaAnnotations(request, 0))

test('the title pill opens a menu named after the set, grouped by directory, current file marked', async ({ page, request }) => {
  const { 'alpha.md': alpha } = await files(request)
  await open(page, alpha.id)
  await expect(page.locator('#file-menu')).toBeHidden()
  await openMenu(page)
  await expect(page.locator('#file-menu .fm-title')).toHaveText('e2e')
  await expect(page.locator('#file-menu .fm-item')).toHaveCount(3)
  await expect(page.locator('#file-menu .fm-group')).toHaveText(['a', 'b'])
  await expect(page.locator('#file-menu .fm-item.current')).toHaveText('alpha.md')
})

test('menu closes on Escape and on a click outside', async ({ page, request }) => {
  const { 'alpha.md': alpha } = await files(request)
  await open(page, alpha.id)
  await openMenu(page)
  await page.keyboard.press('Escape')
  await expect(page.locator('#file-menu')).toBeHidden()
  await openMenu(page)
  await page.mouse.click(900, 600)
  await expect(page.locator('#file-menu')).toBeHidden()
})

test('picking a file swaps the document in place, without reloading the page', async ({ page, request }) => {
  const { 'alpha.md': alpha, 'beta.md': beta } = await files(request)
  await open(page, alpha.id)
  await page.evaluate(() => { (window as unknown as { noReload: boolean }).noReload = true })
  await expect(page.locator('.cm-content')).toContainText('Natural wine')

  await pick(page, 'beta.md')

  await expect(page.locator('.cm-content')).toContainText('Orange wine')
  await expect(page.locator('.cm-content')).not.toContainText('Natural wine')
  await expect(page).toHaveURL(new RegExp(`file=${beta.id}`))
  await expect(page.locator('#filename-display')).toHaveText('beta.md')
  await expect(page.locator('#file-menu')).toBeHidden()
  expect(await page.evaluate(() => (window as unknown as { noReload?: boolean }).noReload)).toBe(true)
})

test('back and forward move between files without reloading', async ({ page, request }) => {
  const { 'alpha.md': alpha } = await files(request)
  await open(page, alpha.id)
  await pick(page, 'beta.md')
  await expect(page.locator('.cm-content')).toContainText('Orange wine')

  await page.goBack()
  await expect(page.locator('.cm-content')).toContainText('Natural wine')
  await expect(page.locator('#filename-display')).toHaveText('alpha.md')
  await page.goForward()
  await expect(page.locator('.cm-content')).toContainText('Orange wine')
})

test('pending badge follows the file whose annotations change, live', async ({ page, request }) => {
  const { 'alpha.md': alpha } = await files(request)
  await open(page, alpha.id)
  await openMenu(page)
  const alphaItem = page.locator('#file-menu .fm-item', { hasText: 'alpha.md' })
  const betaItem = page.locator('#file-menu .fm-item', { hasText: 'beta.md' })
  await expect(betaItem.locator('.fm-badge')).toBeHidden()

  await setBetaAnnotations(request, 2)
  await expect(betaItem.locator('.fm-badge')).toHaveText('2')
  await expect(alphaItem.locator('.fm-badge')).toBeHidden()
})

test('annotations stay with their file', async ({ request }) => {
  const { 'alpha.md': alpha, 'beta.md': beta } = await files(request)
  await setBetaAnnotations(request, 1)
  const onAlpha = await (await request.get(`/api/folio?file=${alpha.id}`)).json()
  const onBeta = await (await request.get(`/api/folio?file=${beta.id}`)).json()
  expect(onAlpha.annotations).toHaveLength(0)
  expect(onBeta.annotations).toHaveLength(1)
  expect((await request.get('/api/file?file=nope')).status()).toBe(404)
})

test('annotation cards of the previous file do not linger after a swap', async ({ page, request }) => {
  const { 'alpha.md': alpha } = await files(request)
  await setBetaAnnotations(request, 1)
  await open(page, alpha.id)
  await page.click('#toggle-gutter-btn')
  await expect(page.locator('#raw-annotation-gutter .ann-card')).toHaveCount(0)

  await pick(page, 'beta.md')
  await expect(page.locator('#raw-annotation-gutter .ann-card')).toHaveCount(1)

  await pick(page, 'alpha.md')
  await expect(page.locator('.cm-content')).toContainText('Natural wine')
  await expect(page.locator('#raw-annotation-gutter .ann-card')).toHaveCount(0)
})

test('an edit made just before switching is saved', async ({ page, request }) => {
  const { 'alpha.md': alpha } = await files(request)
  await open(page, alpha.id)
  await page.locator('.cm-content').click()
  await page.keyboard.press('ControlOrMeta+End')
  await page.keyboard.type('UNSAVED-MARKER')
  await pick(page, 'beta.md')
  await expect.poll(async () => (await request.get(`/api/file?file=${alpha.id}`)).text())
    .toContain('UNSAVED-MARKER')
})

test('undo in the new file never reaches back into the previous one', async ({ page, request }) => {
  const { 'alpha.md': alpha, 'beta.md': beta } = await files(request)
  await open(page, alpha.id)
  await page.locator('.cm-content').click()
  await page.keyboard.press('ControlOrMeta+End')
  await page.keyboard.type('UNDO-MARKER')

  await pick(page, 'beta.md')
  await expect(page.locator('.cm-content')).toContainText('Orange wine')
  const before = await (await request.get(`/api/file?file=${beta.id}`)).text()

  await page.locator('.cm-content').click()
  await page.keyboard.press('ControlOrMeta+z')
  await expect(page.locator('.cm-content')).toContainText('Orange wine')
  await expect(page.locator('.cm-content')).not.toContainText('UNDO-MARKER')
  expect(await (await request.get(`/api/file?file=${beta.id}`)).text()).toBe(before)
})

for (const [mode, wrapper] of [['source', '#raw-editor-wrapper'], ['preview', '#editor-wrapper']] as const) {
  test(`scroll position is restored when coming back to a file (${mode})`, async ({ page, request }) => {
    const { 'long.md': long } = await files(request)
    await open(page, long.id)
    if (mode === 'preview') {
      await page.click('#view-toggle-btn')
      await page.waitForSelector('#editor-tiptap .ProseMirror', { state: 'visible' })
    }
    const scrollTop = () => page.locator(wrapper).evaluate(el => el.scrollTop)
    // The document must have laid out before there is anything to scroll.
    await expect.poll(() => page.locator(wrapper).evaluate(el => el.scrollHeight - el.clientHeight))
      .toBeGreaterThan(1600)
    await page.locator(wrapper).evaluate(el => { el.scrollTop = 1500 })
    const before = await scrollTop()
    expect(before).toBeGreaterThan(1000)

    await pick(page, 'alpha.md')
    await expect(page.locator(mode === 'source' ? '.cm-content' : '#editor-tiptap')).toContainText('Natural wine')
    await expect.poll(scrollTop).toBe(0)

    await pick(page, 'long.md')
    await expect(page.locator(mode === 'source' ? '.cm-content' : '#editor-tiptap')).toContainText('Paragraph')
    await expect.poll(scrollTop).toBeGreaterThan(before - 80)
    expect(await scrollTop()).toBeLessThan(before + 80)
  })
}

test('comment pane and view mode carry over to the next file', async ({ page, request }) => {
  const { 'alpha.md': alpha } = await files(request)
  await open(page, alpha.id)
  await page.click('#toggle-gutter-btn')
  await page.click('#view-toggle-btn')
  await page.waitForSelector('#editor-tiptap .ProseMirror', { state: 'visible' })

  await pick(page, 'beta.md')
  await expect(page.locator('#editor-tiptap')).toContainText('Orange wine')
  await expect(page.locator('#editor-tiptap .ProseMirror')).toBeVisible()
  await expect(page.locator('#app')).toHaveClass(/gutter-open/)
})
