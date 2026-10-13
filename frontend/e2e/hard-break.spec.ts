import { test, expect } from './fixtures'

test('an annotation after a hard break highlights its target in preview', async ({ page, request }) => {
  await request.put('/api/folio', { data: { version: 1, annotations: [{
    id: 'hb1', kind: 'comment', source: 'agent', author: 'agent', comment: 'Check',
    context_before: 'A second paragraph gives the tests something else to select and annotate.Description:',
    target: 'The sample application', created: '2026-01-01T00:00:00Z', resolved: false,
  }] } })
  await page.goto('/')
  await page.waitForSelector('.cm-content')
  await page.click('#view-toggle-btn')
  await expect(page.locator('#editor-wrapper .ann-comment-target').first()).toHaveText('The sample application')
})
