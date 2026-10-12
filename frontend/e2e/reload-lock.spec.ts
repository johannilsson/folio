import { test, expect } from './fixtures'
import { readFileSync } from 'fs'
import { join } from 'path'

// Reloading changed text into the live preview used to leave it read-only for content
// that a fresh editor maps back to the source fine (seen after a git pull).
test('preview stays editable when the file changes underneath it', async ({ page, request, bridge }) => {
  test.skip(!bridge, 'needs __folioEmit to stand in for the file watcher')
  const original = readFileSync(join(__dirname, 'fixture.md'), 'utf8')
  const changed = original + '\n\n- a\n- b\n\n| x | y |\n|---|---|\n| 1 | 2 |\n\n```js\nlet a = 1\n```\n'
  await page.goto('/')
  await page.waitForSelector('.cm-content')
  await page.click('#view-toggle-btn')
  await page.waitForSelector('#editor-tiptap .ProseMirror', { state: 'visible' })
  await request.put('/api/file', { data: changed })
  await page.evaluate(() => (window as any).__folioEmit('md:changed'))
  await expect(page.locator('#editor-tiptap')).toContainText('let a = 1')
  await expect(page.locator('#preview-readonly-notice')).toBeHidden()
  await expect(page.locator('#editor-tiptap .ProseMirror')).toHaveAttribute('contenteditable', 'true')
  await request.put('/api/file', { data: original })
})
