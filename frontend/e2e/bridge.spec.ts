import { test, expect } from './fixtures'

// Guards the other specs: without this, a broken mock would silently leave the
// "bridge" project running over plain HTTP. __folioEmit only exists when the page
// took the native path.
test('the page takes the native path only when a bridge is present', async ({ page, bridge }) => {
  await page.goto('/')
  await page.waitForSelector('.cm-content')
  const hasEmit = await page.evaluate(() => typeof (window as any).__folioEmit === 'function')
  expect(hasEmit).toBe(bridge)
})

test('a bridge failure rejects instead of hanging', async ({ page, bridge }) => {
  test.skip(!bridge, 'bridge only')
  await page.goto('/')
  await page.waitForSelector('.cm-content')
  const message = await page.evaluate(() =>
    (window as any).webkit.messageHandlers.folio.postMessage({ op: 'nope' }).catch((e: Error) => e.message))
  expect(message).toContain('unknown op')
})
