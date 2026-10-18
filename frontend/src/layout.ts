import { call } from './bridge'
import { scheduleAnchorReport } from './annotations'

// The page does not scroll: it lays itself out at its full height and the app's scroll
// view scrolls it. So the app needs two things from the page: how tall it is, and what has
// to come into view (the caret while typing, a match from Find, an element asked to
// `scrollIntoView`). Both go over the bridge (`layout`, `reveal`; see macos/BRIDGE.md).

const reveal = (rect: { top: number; bottom: number }): void => {
  void call('reveal', { top: rect.top, bottom: rect.bottom }).catch(console.error)
}

/** Make the selection visible: its far end, or all of it for a match from Find. */
function revealSelection(whole = false): void {
  const sel = getSelection()
  if (!sel || sel.rangeCount === 0 || !sel.focusNode) return
  const range = sel.getRangeAt(0).cloneRange()
  if (!whole) range.collapse(false)
  let rect = range.getBoundingClientRect()
  if (rect.height === 0) {
    // A collapsed range has no box in some positions; fall back to the line around it.
    const el = sel.focusNode instanceof Element ? sel.focusNode : sel.focusNode.parentElement
    if (!el) return
    rect = el.getBoundingClientRect()
  }
  reveal(rect)
}

const w = window as unknown as {
  __folioViewport: (height: number) => void
  __folioRevealSelection: () => void
}

// The visible height of the window, for what should fill it (the preview's click target
// below a short document).
w.__folioViewport = height => document.documentElement.style.setProperty('--viewport-h', `${height}px`)

// Find selects its match without any input from the page.
w.__folioRevealSelection = () => revealSelection(true)

// `scrollIntoView` has nothing to scroll in the page, so it asks the app instead.
Element.prototype.scrollIntoView = function (this: Element) {
  reveal(this.getBoundingClientRect())
}

export function initLayoutReporting(): void {
  const reportHeight = () => {
    const height = Math.ceil(document.body.getBoundingClientRect().height)
    void call('layout', { height }).catch(console.error)
    // Text may have moved (a window resize, a diagram that finished loading).
    scheduleAnchorReport()
  }
  new ResizeObserver(reportHeight).observe(document.body)

  // A click anywhere in the page, before the page acts on it: the app closes what it has open
  // over the text. A click on annotated text then reports it (`focus`).
  document.addEventListener('mousedown', () => { void call('pointer').catch(console.error) }, true)

  // Typing and keyboard selection move the selection under the reader's hands, so it is
  // revealed; the page changing it by itself (a reload) must not move the window.
  let lastInput = 0
  for (const type of ['keydown', 'input', 'mousedown', 'mouseup', 'compositionend']) {
    document.addEventListener(type, () => { lastInput = performance.now() }, true)
  }
  // The app routes Undo to the last thing the reader did, so it needs to know about typing.
  document.addEventListener('input', () => { void call('typing').catch(console.error) }, true)
  document.addEventListener('selectionchange', () => {
    if (performance.now() - lastInput < 300) revealSelection()
  })
}
