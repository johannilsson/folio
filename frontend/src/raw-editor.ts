import { EditorState, StateField, StateEffect, Annotation as CmTxAnnotation } from '@codemirror/state'
import { EditorView, Decoration } from '@codemirror/view'
import type { DecorationSet, ViewUpdate } from '@codemirror/view'
import { markdown } from '@codemirror/lang-markdown'
import { basicSetup } from 'codemirror'
import type { Annotation as FolioAnnotation } from './api'
import { putFile, postAnchorRaw } from './api'
import { getSidecar } from './annotations'

// Marks a transaction as a programmatic content replacement (setRawContent),
// as opposed to a real user keystroke — the CM6 analog of Tiptap's
// `emitUpdate: false`, so the save listener never re-saves/loops on it.
const externalUpdate = CmTxAnnotation.define<boolean>()

interface RawAnchor {
  from: number
  to: number
  kind: FolioAnnotation['kind']
}

const setAnnotationDecos = StateEffect.define<RawAnchor[]>()

function cssClassFor(kind: FolioAnnotation['kind']): string {
  switch (kind) {
    case 'delete':
    case 'replace':
      return 'cm-ann-delete'
    case 'comment':
      return 'cm-ann-comment-target'
    case 'highlight':
    default:
      return 'cm-ann-highlight'
  }
}

const annotationField = StateField.define<DecorationSet>({
  create: () => Decoration.none,
  update(decos, tr) {
    decos = decos.map(tr.changes)
    for (const e of tr.effects) {
      if (e.is(setAnnotationDecos)) {
        const marks = e.value
          .filter(a => a.from !== a.to)
          .map(a => Decoration.mark({ class: cssClassFor(a.kind) }).range(a.from, a.to))
        decos = Decoration.set(marks, true)
      }
    }
    return decos
  },
  provide: f => EditorView.decorations.from(f),
})

let view: EditorView | null = null
let saveTimer: ReturnType<typeof setTimeout> | null = null

function updateListener(update: ViewUpdate): void {
  if (!update.docChanged) return
  const isExternal = update.transactions.some(tr => tr.annotation(externalUpdate))
  if (isExternal) return
  if (saveTimer) clearTimeout(saveTimer)
  saveTimer = setTimeout(() => {
    if (view) putFile(view.state.doc.toString())
  }, 300)
}

export function initRawEditor(container: HTMLElement, initialContent: string): void {
  if (view) return
  view = new EditorView({
    parent: container,
    state: EditorState.create({
      doc: initialContent,
      extensions: [
        basicSetup,
        markdown(),
        EditorView.lineWrapping,
        annotationField,
        EditorView.updateListener.of(updateListener),
      ],
    }),
  })
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

export function getRawScrollDOM(): HTMLElement | null {
  return view?.scrollDOM ?? null
}

export function refreshRawAnnotations(): void {
  if (!view) return
  const pending = getSidecar().annotations.filter(a => !a.resolved)
  if (pending.length === 0) {
    view.dispatch({ effects: setAnnotationDecos.of([]) })
    return
  }
  const items = pending.map(a => ({ id: a.id, context_before: a.context_before, target: a.target ?? undefined }))
  postAnchorRaw(items).then(results => {
    if (!view) return
    const byId = new Map(results.map(r => [r.id, r]))
    const anchors: RawAnchor[] = []
    for (const ann of pending) {
      const r = byId.get(ann.id)
      if (r?.char_from != null && r?.char_to != null) {
        anchors.push({ from: r.char_from, to: r.char_to, kind: ann.kind })
      }
    }
    view.dispatch({ effects: setAnnotationDecos.of(anchors) })
  })
}
