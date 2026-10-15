// Brief confirmation after an annotation is accepted or removed, since the card
// and its decoration disappear instantly.

let toastEl: HTMLElement | null = null
let toastTimer: ReturnType<typeof setTimeout> | null = null

export function hideToast(): void {
  if (toastTimer) clearTimeout(toastTimer)
  toastTimer = null
  if (toastEl) toastEl.hidden = true
}

export function showToast(message: string, onUndo?: () => void): void {
  if (!toastEl) {
    toastEl = document.createElement('div')
    toastEl.id = 'folio-toast'
    toastEl.setAttribute('role', 'status')
    document.body.appendChild(toastEl)
  }
  toastEl.replaceChildren()
  const text = document.createElement('span')
  text.textContent = message
  toastEl.appendChild(text)
  if (onUndo) {
    const undo = document.createElement('button')
    undo.textContent = 'Undo'
    undo.addEventListener('mousedown', e => {
      e.preventDefault()
      hideToast()
      onUndo()
    })
    toastEl.appendChild(undo)
  }
  toastEl.hidden = false
  // Centre on the text column, not the window: the comment pane takes space on the right.
  const column = ['#editor-tiptap', '#raw-pane .cm-editor']
    .map(sel => document.querySelector<HTMLElement>(sel))
    .find(el => el && el.offsetParent !== null)
  if (column) {
    const r = column.getBoundingClientRect()
    toastEl.style.left = `${r.left + r.width / 2}px`
  }
  if (toastTimer) clearTimeout(toastTimer)
  toastTimer = setTimeout(hideToast, 4000)
}

// Briefly highlights the first occurrence of `text` inside the visible editor, using
// the CSS Custom Highlight API so neither ProseMirror nor CM6 sees any change.
export function flashText(text: string): boolean {
  const needle = text.trim()
  if (!needle || !('highlights' in CSS)) return true
  const root = ['#editor-wrapper', '#raw-editor-wrapper']
    .map(sel => document.querySelector<HTMLElement>(sel))
    .find(el => el && el.offsetParent !== null)
  if (!root) return false
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT)
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    const i = node.textContent?.indexOf(needle) ?? -1
    if (i < 0 || node.parentElement?.closest('.ann-replace-preview, .ann-insert-preview, .cm-ann-preview')) continue
    const range = new Range()
    range.setStart(node, i)
    range.setEnd(node, i + needle.length)
    CSS.highlights.set('folio-flash', new Highlight(range))
    setTimeout(() => CSS.highlights.delete('folio-flash'), 1500)
    return true
  }
  return false
}

// Accept in the preview goes through the server; the text only changes once the
// reloaded document arrives, so the flash waits for it.
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
