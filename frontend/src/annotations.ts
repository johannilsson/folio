import { Extension } from '@tiptap/core'
import type { Editor, JSONContent } from '@tiptap/core'
import { Plugin, PluginKey, TextSelection } from '@tiptap/pm/state'
import { Decoration, DecorationSet } from '@tiptap/pm/view'
import { DOMSerializer, Node as PMNode } from '@tiptap/pm/model'
import type { EditorView } from '@tiptap/pm/view'
import type { Annotation, Sidecar } from './api'
import { postAnchor } from './api'
import { call } from './bridge'
import { flushSave } from './editor'
import { flashAfterReload } from './feedback'

// ─── Sidecar state ───────────────────────────────────────────────────────────

let currentSidecar: Sidecar = { version: 1, annotations: [] }

// The preview's inline marks are drawn here; the cards, overlay, comment button and form are
// the app's (macos/Sources/Folio/Annotations). This module tells the app where the annotations
// are, what is selected and what was clicked (the `anchors`, `selection` and `focus` ops), and
// takes its requests (`__folioSetPending`, `__folioSelectAnnotation`, ...; see macos/BRIDGE.md).

// Text the reader is commenting on, kept highlighted while the app's comment form is open.
let pendingCommentRange: { from: number; to: number } | null = null
let currentView: EditorView | null = null
// Set when the whole document is replaced: the app may have forgotten what this page reported
// (it was showing the source), so the next report is sent even if nothing changed.
let resendReports = false

// Returns true when the incoming sidecar is the one we already have (an echo of a write).
export function updateSidecar(sidecar: Sidecar): boolean {
  const isEcho = JSON.stringify(sidecar) === JSON.stringify(currentSidecar)
  currentSidecar = sidecar
  return isEcho
}

// Forget everything tied to the previous document before another is mounted.
export function resetAnnotationState(): void {
  currentSidecar = { version: 1, annotations: [] }
  pendingCommentRange = null
}

// Dispatch a full re-anchor. Call after an external sidecar change (new agent
// annotations); do NOT call for echoes of our own PUTs.
export function triggerSidecarUpdate(ed: Editor): void {
  ed.view.dispatch(ed.state.tr.setMeta(annotationsKey, { type: 'sidecar-updated' }))
}

// Call after setContent() replaces the entire document. Clears stale anchor
// positions (which would otherwise be mapped to position 0 by ProseMirror's
// full-document replacement step) and triggers a fresh re-anchor.
export function triggerContentReplaced(ed: Editor): void {
  resendReports = true
  ed.view.dispatch(ed.state.tr.setMeta(annotationsKey, { type: 'content-replaced' }))
}

// ─── Plugin state ─────────────────────────────────────────────────────────────

interface AnnotationsPluginState {
  anchors: Map<string, { from: number; to: number }>
  decoSet: DecorationSet
  needsReanchor: boolean
  anchorVersion: number
}

const annotationsKey = new PluginKey<AnnotationsPluginState>('folioAnnotations')

// ─── Anchoring ───────────────────────────────────────────────────────────────

// Build the document's rendered plain text, which the server anchors against,
// and a map from each of its indices to the ProseMirror position. Used to
// convert server-returned indices to PM positions for decorations.
export function buildCharPos(doc: PMNode): { text: string; charPos: number[] } {
  const charPos: number[] = []
  let text = ''
  doc.descendants((node, pos) => {
    // Skip code block content, as strip_markdown skips fenced blocks, so
    // contexts agents copied from `folio render` keep matching.
    if (node.type.name === 'codeBlock') return false
    if (node.isText) {
      for (let i = 0; i < node.text!.length; i++) {
        // A soft line break stays a "\n" in the text node; strip_markdown drops it.
        if (node.text![i] === '\n') continue
        text += node.text![i]
        charPos.push(pos + i)
      }
    }
  })
  return { text, charPos }
}

// Convert char indices (from, to) in the rendered plain text to ProseMirror
// positions using the charPos map produced by buildCharPos.
//
// When fromIdx === toIdx (insert/comment — no target), the result is a single
// point just after the last char of context_before, staying inside the same
// block rather than jumping to the next one.
export function charIndexToRange(
  charPos: number[],
  fromIdx: number,
  toIdx: number,
): { from: number; to: number } {
  const from =
    toIdx > fromIdx
      ? fromIdx < charPos.length
        ? charPos[fromIdx]
        : charPos[charPos.length - 1] + 1
      : fromIdx > 0
        ? charPos[fromIdx - 1] + 1
        : charPos.length > 0 ? charPos[0] : 0
  const to =
    toIdx > fromIdx
      ? toIdx - 1 < charPos.length
        ? charPos[toIdx - 1] + 1
        : charPos[charPos.length - 1] + 1
      : from
  return { from, to }
}

// ─── Inline decorations ───────────────────────────────────────────────────────

function renderMarkdownContent(markdown: string, editor: Editor): Node {
  try {
    const mgr = editor.storage.markdown as { manager: { parse: (s: string) => JSONContent } }
    const json = mgr.manager.parse(markdown)
    const pmNode = PMNode.fromJSON(editor.state.schema, json)
    return DOMSerializer.fromSchema(editor.state.schema).serializeFragment(pmNode.content)
  } catch {
    const frag = document.createDocumentFragment()
    const span = document.createElement('span')
    span.textContent = markdown
    frag.appendChild(span)
    return frag
  }
}

function buildPreviewEl(replacement: string, editor: Editor): HTMLElement {
  const tempDiv = document.createElement('div')
  tempDiv.appendChild(renderMarkdownContent(replacement, editor))

  if (tempDiv.querySelector('table, pre')) {
    const el = document.createElement('div')
    el.className = 'ann-replace-preview'
    while (tempDiv.firstChild) el.appendChild(tempDiv.firstChild)
    return el
  }

  if (tempDiv.querySelector('h1, h2, h3, h4, h5, h6')) {
    const el = document.createElement('div')
    el.className = 'ann-insert-preview'
    while (tempDiv.firstChild) el.appendChild(tempDiv.firstChild)
    return el
  }

  const el = document.createElement('span')
  el.className = 'ann-insert-preview'
  const blocks = Array.from(tempDiv.querySelectorAll('p, li'))
  if (blocks.length > 0) {
    blocks.forEach((block, i) => {
      if (i > 0) el.appendChild(document.createElement('br'))
      while (block.firstChild) el.appendChild(block.firstChild)
    })
  } else {
    el.textContent = replacement
  }
  return el
}

// A click on an inline suggestion widget focuses its card, like a click on annotated text.
function previewWidget(ann: Annotation, editor: Editor): HTMLElement {
  const el = buildPreviewEl(ann.replacement!, editor)
  el.addEventListener('mousedown', e => {
    e.stopPropagation()
    reportFocus(ann.id)
  })
  return el
}

function buildDecosFromAnchors(
  anchors: Map<string, { from: number; to: number }>,
  doc: PMNode,
  editor: Editor,
): DecorationSet {
  const pending = currentSidecar.annotations.filter(a => !a.resolved)
  const decos: Decoration[] = []

  for (const ann of pending) {
    const anchor = anchors.get(ann.id)
    if (!anchor) continue

    const { from, to } = anchor

    switch (ann.kind) {
      case 'delete':
        decos.push(Decoration.inline(from, to, { class: 'ann-delete' }))
        break
      case 'replace':
        decos.push(Decoration.inline(from, to, { class: 'ann-delete' }))
        if (ann.replacement) {
          decos.push(
            Decoration.widget(to, () => previewWidget(ann, editor), { side: 1, key: `${ann.id}-preview` }),
          )
        }
        break
      case 'insert':
        if (ann.replacement) {
          decos.push(
            Decoration.widget(from, () => previewWidget(ann, editor), { side: -1, key: `${ann.id}-preview` }),
          )
        }
        break
      case 'highlight':
        decos.push(Decoration.inline(from, to, { class: 'ann-highlight' }))
        break
      case 'comment':
        if (from !== to) {
          decos.push(Decoration.inline(from, to, { class: 'ann-comment-target' }))
        }
        break
    }
  }

  if (pendingCommentRange) {
    decos.push(Decoration.inline(pendingCommentRange.from, pendingCommentRange.to, { class: 'ann-comment-pending' }))
  }

  return DecorationSet.create(doc, decos)
}

// ─── Reporting to the app ────────────────────────────────────────────────────

const reportFocus = (id: string | null): void => {
  void call('focus', { id }).catch(console.error)
}

let reportQueued = false

/** Report where the annotations and the selection are, on the next frame. */
export function scheduleAnchorReport(): void {
  if (reportQueued) return
  reportQueued = true
  requestAnimationFrame(() => {
    reportQueued = false
    window.dispatchEvent(new Event('folio:report'))
  })
}

// The app asks the preview for things by name; see macos/BRIDGE.md.
const w = window as unknown as {
  __folioSetPending: (range: { from: number; to: number } | null) => void
  __folioSelectAnnotation: (id: string) => void
  __folioFlush: () => Promise<unknown>
  __folioFlashAfterReload: (text: string) => void
}

// Keeps the text being commented on highlighted while the form is open.
w.__folioSetPending = range => {
  pendingCommentRange = range
  currentView?.dispatch(currentView.state.tr.setMeta(annotationsKey, { type: 'refresh' }))
}

// Puts the caret at the start of an annotation (keyboard navigation).
w.__folioSelectAnnotation = id => {
  const view = currentView
  const anchor = view && annotationsKey.getState(view.state)?.anchors.get(id)
  if (!view || !anchor) return
  view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, anchor.from)))
  view.focus()
}

// Saves pending edits, so accepting patches the text as it is on screen.
w.__folioFlush = () => flushSave()

// The text changes only once the reloaded document arrives, so the flash waits for it.
w.__folioFlashAfterReload = text => flashAfterReload(text)

// ─── Extension ───────────────────────────────────────────────────────────────

export function createAnnotationsExtension(): Extension {
  return Extension.create({
    name: 'folioAnnotations',

    addProseMirrorPlugins() {
      const editor = this.editor

      return [
        new Plugin({
          key: annotationsKey,

          state: {
            init(): AnnotationsPluginState {
              // Anchors are populated asynchronously via the plugin view;
              // start with empty anchors and signal that a fetch is needed.
              return {
                anchors: new Map(),
                decoSet: DecorationSet.empty,
                needsReanchor: true,
                anchorVersion: 0,
              }
            },

            apply(tr, value): AnnotationsPluginState {
              const meta = tr.getMeta(annotationsKey) as
                | { type: string; id?: string; anchors?: Map<string, { from: number; to: number }> }
                | undefined

              if (meta?.type === 'sidecar-updated') {
                // External sidecar change: signal the view to fetch fresh anchors.
                // Keep existing anchors visible until the server response arrives.
                return { ...value, needsReanchor: true, anchorVersion: value.anchorVersion + 1 }
              }

              if (meta?.type === 'content-replaced') {
                // The entire document was replaced (e.g. coming back from the source).
                // Any mapped positions are invalid — clear them immediately so
                // decorations don't render at position 0, then re-anchor from scratch.
                return {
                  anchors: new Map(),
                  decoSet: DecorationSet.empty,
                  needsReanchor: true,
                  anchorVersion: value.anchorVersion + 1,
                }
              }

              if (meta?.type === 'anchors-ready') {
                const anchors = meta.anchors!
                return {
                  anchors,
                  decoSet: buildDecosFromAnchors(anchors, tr.doc, editor),
                  needsReanchor: false,
                  anchorVersion: value.anchorVersion,
                }
              }

              if (meta?.type === 'refresh') {
                // Rebuild decorations from existing anchors (e.g. pendingCommentRange changed).
                return { ...value, decoSet: buildDecosFromAnchors(value.anchors, tr.doc, editor) }
              }

              if (!tr.docChanged) return value

              // Doc changed: map every stored position through the transaction mapping.
              // This keeps annotation positions correct without any text search —
              // critical when an accept modifies text that other annotations reference
              // in their context_before fields.
              const anchors = new Map<string, { from: number; to: number }>()
              for (const [id, pos] of value.anchors) {
                anchors.set(id, {
                  from: tr.mapping.map(pos.from),
                  to: tr.mapping.map(pos.to, -1),
                })
              }
              return { ...value, anchors, decoSet: buildDecosFromAnchors(anchors, tr.doc, editor) }
            },
          },

          props: {
            decorations(state) {
              return annotationsKey.getState(state)!.decoSet
            },
            handleClick(view, pos) {
              const pluginAnchors = annotationsKey.getState(view.state)?.anchors
              let found: string | null = null
              for (const ann of currentSidecar.annotations) {
                if (ann.resolved) continue
                const anchor = pluginAnchors?.get(ann.id)
                if (anchor && pos >= anchor.from && pos <= anchor.to) {
                  found = ann.id
                  break
                }
              }
              reportFocus(found)
              return false
            },
          },

          view(pmView) {
            currentView = pmView
            let pendingRequest = false
            let pendingVersion = -1

            // Fire an anchor fetch if one is needed and none is already in flight.
            // Called on initial mount (update() is not called on first creation in
            // ProseMirror) and on each subsequent state update.
            function tryFetchAnchors(view: EditorView) {
              if (pendingRequest) return
              const pluginState = annotationsKey.getState(view.state)
              if (!pluginState?.needsReanchor) return

              pendingRequest = true
              pendingVersion = pluginState.anchorVersion
              const { text, charPos } = buildCharPos(view.state.doc)
              const items = currentSidecar.annotations
                .filter(a => !a.resolved)
                .map(a => ({ id: a.id, context_before: a.context_before, target: a.target ?? undefined }))

              postAnchor(text, items)
                .then(results => {
                  pendingRequest = false
                  if (annotationsKey.getState(view.state)?.anchorVersion !== pendingVersion) {
                    // A newer sidecar arrived while we were waiting — dispatch a no-op
                    // so update() runs again and fires a fresh request.
                    view.dispatch(view.state.tr)
                    return
                  }
                  const anchors = new Map<string, { from: number; to: number }>()
                  for (const result of results) {
                    if (result.char_from != null && result.char_to != null) {
                      anchors.set(result.id, charIndexToRange(charPos, result.char_from, result.char_to))
                    }
                  }
                  view.dispatch(view.state.tr.setMeta(annotationsKey, { type: 'anchors-ready', anchors }))
                })
                .catch(() => { pendingRequest = false })
            }

            // Where each pending annotation starts, in page coordinates (the page does not
            // scroll). Only once anchoring has answered; until then the app keeps what it has.
            let lastAnchors = ''
            function reportAnchors(view: EditorView) {
              const state = annotationsKey.getState(view.state)
              if (!state || state.needsReanchor) return
              const anchors: Array<{ id: string; from: number; top: number; bottom: number; left: number }> = []
              for (const ann of currentSidecar.annotations) {
                const anchor = ann.resolved ? undefined : state.anchors.get(ann.id)
                if (!anchor) continue
                try {
                  const c = view.coordsAtPos(anchor.from)
                  anchors.push({ id: ann.id, from: anchor.from, top: c.top, bottom: c.bottom, left: c.left })
                } catch {
                  // Not laid out yet: the next report has it.
                }
              }
              const json = JSON.stringify(anchors)
              if (json === lastAnchors) return
              lastAnchors = json
              void call('anchors', { anchors }).catch(console.error)
            }

            // The selected text, for the app's Comment button: where it is, and the words an
            // annotation is anchored by (concatenated without a separator, like the anchoring).
            let lastSelection = ''
            function reportSelection(view: EditorView) {
              const { selection, doc } = view.state
              let selected: Record<string, unknown> | null = null
              if (!selection.empty) {
                try {
                  const start = view.coordsAtPos(selection.from)
                  const end = view.coordsAtPos(selection.to)
                  selected = {
                    from: selection.from,
                    to: selection.to,
                    top: start.top,
                    bottom: start.bottom,
                    endBottom: end.bottom,
                    left: start.left,
                    right: end.right,
                    target: doc.textBetween(selection.from, selection.to, ''),
                    contextBefore: doc.textBetween(0, selection.from, '').slice(-30),
                  }
                } catch {
                  selected = null
                }
              }
              const json = JSON.stringify(selected)
              if (json === lastSelection) return
              lastSelection = json
              void call('selection', { selection: selected }).catch(console.error)
            }

            const report = () => {
              if (resendReports) {
                lastAnchors = ''
                lastSelection = ''
                resendReports = false
              }
              reportAnchors(pmView)
              reportSelection(pmView)
            }
            window.addEventListener('folio:report', report)

            // Anchoring has to be asked for on mount: update() is not called on first mount.
            tryFetchAnchors(pmView)
            scheduleAnchorReport()

            return {
              update(view) {
                tryFetchAnchors(view)
                scheduleAnchorReport()
              },
              destroy() {
                window.removeEventListener('folio:report', report)
                if (currentView === pmView) currentView = null
                pendingCommentRange = null
              },
            }
          },
        }),
      ]
    },
  })
}
