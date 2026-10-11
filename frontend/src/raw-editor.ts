import { EditorState, Annotation as CmTxAnnotation } from '@codemirror/state'
import type { Extension } from '@codemirror/state'
import { EditorView } from '@codemirror/view'
import type { ViewUpdate } from '@codemirror/view'
import { markdown } from '@codemirror/lang-markdown'
import { basicSetup } from 'codemirror'
import { HighlightStyle, syntaxHighlighting } from '@codemirror/language'
import { tags } from '@lezer/highlight'
import { putFile } from './api'
import { rawAnnotationExtensions, mountRawGutter, refreshRawAnnotations as refreshRawAnnotationsFor, resetRawAnnotationState, setGutterHidden as setRawGutterHidden } from './raw-annotations'
import { rawFormattingKeymap } from './raw-formatting'
import { tableRowLayout } from './raw-table-layout'

// Marks a transaction as a programmatic content replacement (setRawContent),
// as opposed to a real user keystroke — the CM6 analog of Tiptap's
// `emitUpdate: false`, so the save listener never re-saves/loops on it.
const externalUpdate = CmTxAnnotation.define<boolean>()

// CM6 scrolls internally by default (.cm-scroller{overflow:auto}). The gutter
// needs to scroll in lockstep with the text (CLAUDE.md's documented gutter
// pattern), so #raw-editor-wrapper is the real scroll container instead.
const nonScrollingTheme = EditorView.theme({
  '&': { height: 'auto' },
  '.cm-scroller': { overflow: 'visible' },
})

// Overrides defaultHighlightStyle's bold headings (listed first = higher precedence).
const thinHeadings = syntaxHighlighting(HighlightStyle.define([
  { tag: [tags.heading1, tags.heading2, tags.heading3, tags.heading4, tags.heading5, tags.heading6], fontWeight: '500' },
]))

let view: EditorView | null = null
let wrapperEl: HTMLElement | null = null
let saveTimer: ReturnType<typeof setTimeout> | null = null

function updateListener(update: ViewUpdate): void {
  if (!update.docChanged) return
  const isExternal = update.transactions.some(tr => tr.annotation(externalUpdate))
  if (isExternal) return
  if (saveTimer) clearTimeout(saveTimer)
  saveTimer = setTimeout(() => {
    saveTimer = null
    if (view) putFile(view.state.doc.toString())
  }, 300)
}

function extensions(): Extension[] {
  return [
    thinHeadings,
    basicSetup,
    markdown(),
    EditorView.lineWrapping,
    nonScrollingTheme,
    rawFormattingKeymap(),
    tableRowLayout(),
    ...rawAnnotationExtensions(),
    EditorView.updateListener.of(updateListener),
  ]
}

export function initRawEditor(container: HTMLElement, initialContent: string): void {
  if (view) return

  const wrapper = document.createElement('div')
  wrapper.id = 'raw-editor-wrapper'
  const mount = document.createElement('div')
  mount.id = 'raw-editor-mount'
  const gutter = document.createElement('div')
  gutter.id = 'raw-annotation-gutter'
  wrapper.appendChild(mount)
  wrapper.appendChild(gutter)
  container.appendChild(wrapper)
  wrapperEl = wrapper

  view = new EditorView({
    parent: mount,
    state: EditorState.create({
      doc: initialContent,
      extensions: extensions(),
    }),
  })

  mountRawGutter(view, wrapper, gutter)
}

/**
 * Load a different document into the existing editor. A fresh state drops the
 * undo history, so undo can never reach into the previous file. Flush pending
 * edits first: this discards the save timer.
 */
export function resetRawEditor(content: string): void {
  if (!view) return
  if (saveTimer) {
    clearTimeout(saveTimer)
    saveTimer = null
  }
  resetRawAnnotationState()
  view.setState(EditorState.create({ doc: content, extensions: extensions() }))
  if (wrapperEl) wrapperEl.scrollTop = 0
}

export function setRawContent(content: string): void {
  if (!view) return
  if (view.state.doc.toString() === content) return
  view.dispatch({
    changes: { from: 0, to: view.state.doc.length, insert: content },
    annotations: externalUpdate.of(true),
  })
}

export function getRawContent(): string {
  return view?.state.doc.toString() ?? ''
}

export function flushRawSave(): void {
  if (!view) return
  if (saveTimer) {
    clearTimeout(saveTimer)
    saveTimer = null
  }
  putFile(view.state.doc.toString())
}

/** Write only if an edit is still waiting on the debounce timer, so leaving a file never rewrites it unchanged. */
export function flushPendingRawSave(): Promise<unknown> {
  if (!view || !saveTimer) return Promise.resolve()
  clearTimeout(saveTimer)
  saveTimer = null
  return putFile(view.state.doc.toString())
}

export function getRawWrapperEl(): HTMLElement | null {
  return wrapperEl
}

export function refreshRawAnnotations(): void {
  if (view) refreshRawAnnotationsFor(view)
}

export { setRawGutterHidden }
