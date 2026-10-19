// Briefly highlights the first occurrence of `text` inside the preview, using the CSS
// Custom Highlight API so ProseMirror never sees any change.
export function flashText(text: string): boolean {
  const needle = text.trim()
  if (!needle || !('highlights' in CSS)) return true
  const root = document.getElementById('editor-wrapper')
  if (!root) return false
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT)
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    const i = node.textContent?.indexOf(needle) ?? -1
    if (i < 0 || node.parentElement?.closest('.ann-replace-preview, .ann-insert-preview')) continue
    const range = new Range()
    range.setStart(node, i)
    range.setEnd(node, i + needle.length)
    CSS.highlights.set('folio-flash', new Highlight(range))
    setTimeout(() => CSS.highlights.delete('folio-flash'), 1500)
    return true
  }
  return false
}

// Accept goes through the app; the text only changes once the reloaded document arrives,
// so the flash waits for it.
let pendingFlash: { text: string; until: number } | null = null

export function flashAfterReload(text: string): void {
  pendingFlash = { text, until: Date.now() + 5000 }
}

export function runPendingFlash(): void {
  const p = pendingFlash
  if (!p) return
  // Our own file save echoes md:changed before the accepted text is in: keep waiting.
  if (Date.now() >= p.until) { pendingFlash = null; return }
  requestAnimationFrame(() => { if (pendingFlash === p && flashText(p.text)) pendingFlash = null })
}
