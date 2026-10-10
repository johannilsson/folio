import { test, expect, type Page } from '@playwright/test'

type Mode = 'preview' | 'source'

const GUTTER: Record<Mode, string> = { preview: '#annotation-gutter', source: '#raw-annotation-gutter' }
const WRAPPER: Record<Mode, string> = { preview: '#editor-wrapper', source: '#raw-editor-wrapper' }
const LINE: Record<Mode, string> = { preview: '#editor-tiptap p', source: '.cm-line' }

// The app boots in source mode; preview needs one click on the view toggle.
async function open(page: Page, mode: Mode, pane: 'open' | 'closed') {
  await page.goto('/')
  await page.waitForSelector('.cm-content')
  if (mode === 'preview') {
    await page.click('#view-toggle-btn')
    await page.waitForSelector('#editor-tiptap .ProseMirror', { state: 'visible' })
  }
  const isOpen = await page.locator('#app').evaluate(el => el.classList.contains('gutter-open'))
  if (isOpen !== (pane === 'open')) await page.click('#toggle-gutter-btn')
}

// Floater and overlay ids exist in both modes, so scope them to the active wrapper.
const within = (page: Page, mode: Mode, sel: string) => page.locator(`${WRAPPER[mode]} ${sel}`)

async function startComment(page: Page, mode: Mode) {
  await page.locator(LINE[mode], { hasText: 'Natural wine' }).getByText('Natural').first().dblclick()
  await expect(within(page, mode, '#comment-floater')).toBeVisible()
  await within(page, mode, '#comment-floater .af-btn').click()
}

for (const mode of ['preview', 'source'] as const) {
  test.describe(`new comment form (${mode})`, () => {
    test('pane closed: opens as an overlay without opening the pane', async ({ page }) => {
      await open(page, mode, 'closed')
      await startComment(page, mode)
      await expect(within(page, mode, '#comment-form-overlay .cf-gutter-form')).toBeVisible()
      await expect(page.locator('#app')).not.toHaveClass(/gutter-open/)
      await expect(within(page, mode, '#comment-form-overlay .ann-avatar')).toBeVisible()
      await expect(within(page, mode, '#comment-form-overlay .ann-send-btn')).toBeVisible()
    })

    test('pane closed: Esc cancels', async ({ page }) => {
      await open(page, mode, 'closed')
      await startComment(page, mode)
      await within(page, mode, '#comment-form-overlay textarea').fill('draft')
      await page.keyboard.press('Escape')
      await expect(within(page, mode, '#comment-form-overlay')).toBeHidden()
    })

    test('pane closed: clicking outside cancels', async ({ page }) => {
      await open(page, mode, 'closed')
      await startComment(page, mode)
      await page.mouse.click(1200, 700)
      await expect(within(page, mode, '#comment-form-overlay')).toBeHidden()
    })

    test('pane closed: send adds a comment annotation', async ({ page, request }) => {
      const text = `Looks good (${mode})`
      await open(page, mode, 'closed')
      await startComment(page, mode)
      await within(page, mode, '#comment-form-overlay textarea').fill(text)
      await within(page, mode, '#comment-form-overlay .ann-send-btn').click()
      await expect(within(page, mode, '#comment-form-overlay')).toBeHidden()
      await expect.poll(async () => {
        const sidecar = await (await request.get('/api/folio')).json()
        return sidecar.annotations.some((a: { kind: string; comment?: string }) => a.kind === 'comment' && a.comment === text)
      }).toBe(true)
    })

    test('pane open: form stays in the gutter and Esc cancels', async ({ page }) => {
      await open(page, mode, 'open')
      await startComment(page, mode)
      await expect(page.locator(`${GUTTER[mode]} .cf-gutter-form`)).toBeVisible()
      await expect(within(page, mode, '#comment-form-overlay')).toBeHidden()
      await page.keyboard.press('Escape')
      await expect(page.locator(`${GUTTER[mode]} .cf-gutter-form`)).toBeHidden()
    })
  })
}
