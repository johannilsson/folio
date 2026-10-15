import { test as base } from '@playwright/test'

// The "bridge" project runs every spec through the native-app code path: the page
// finds window.webkit.messageHandlers.folio, as it does inside WKWebView. This mock
// answers each op by calling the real folio server, so the whole suite proves the
// bridge contract in macos/BRIDGE.md end to end.
function installBridge() {
  const q = (f?: string | null) => (f ? `?file=${encodeURIComponent(f)}` : '')
  const check = async (r: Response) => {
    if (!r.ok) throw new Error(await r.text())
    return r
  }
  const post = (url: string, body: unknown) =>
    fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) })

  type Msg = { op: string; file?: string | null; [k: string]: any }
  const ops: Record<string, (m: Msg) => Promise<unknown>> = {
    info: m => fetch('/api/info' + q(m.file)).then(r => r.json()),
    files: () => fetch('/api/files').then(r => r.json()),
    getFile: m => fetch('/api/file' + q(m.file)).then(check).then(r => r.text()),
    putFile: m => fetch('/api/file' + q(m.file), { method: 'PUT', body: m.content }).then(check).then(() => null),
    getFolio: m => fetch('/api/folio' + q(m.file)).then(r => r.json()),
    putFolio: m =>
      fetch('/api/folio' + q(m.file), { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: m.body })
        .then(check).then(() => null),
    accept: m => post('/api/accept' + q(m.file), { id: m.id }).then(check).then(() => null),
    uiState: () => Promise.resolve(null),
    krokiUrl: () => fetch('/api/kroki-url').then(r => r.json()).then(d => d.url),
    anchor: m => post('/api/anchor' + q(m.file), { text: m.text, items: m.items }).then(r => r.json()),
    anchorRaw: m => post('/api/anchor-raw' + q(m.file), m.items).then(r => r.json()),
  }

  ;(window as any).webkit = {
    messageHandlers: {
      folio: {
        postMessage: (m: Msg) => {
          const run = ops[m.op]
          return run ? run(m) : Promise.reject(new Error(`unknown op ${m.op}`))
        },
      },
    },
  }

  // Stand-in for Swift's file watchers: relay the server's events to __folioEmit.
  const connect = () => {
    const ws = new WebSocket(`ws://${location.host}/ws`)
    ws.onmessage = e => {
      const msg = JSON.parse(e.data)
      ;(window as any).__folioEmit?.(msg.type, msg.file)
    }
    ws.onclose = () => setTimeout(connect, 2000)
  }
  connect()
}

export const test = base.extend<{ bridge: boolean }>({
  bridge: [false, { option: true }],
  page: async ({ page, bridge }, use) => {
    if (bridge) await page.addInitScript(installBridge)
    await use(page)
  },
})

export { expect } from '@playwright/test'
