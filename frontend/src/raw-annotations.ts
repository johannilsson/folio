import { StateField, StateEffect } from '@codemirror/state'
import type { Extension, Range } from '@codemirror/state'
import { EditorView, Decoration, WidgetType } from '@codemirror/view'
import type { DecorationSet, ViewUpdate } from '@codemirror/view'
import { invertedEffects, isolateHistory } from '@codemirror/commands'
import type { Annotation as FolioAnnotation, Sidecar, ThreadReply } from './api'
import { postAnchorRaw, putFolio, putFile } from './api'
import {
  getSidecar,
  updateSidecar,
  resolveAnnotation,
  addCommentAnnotation,
  repositionCards,
  makeHeader,
  buildThread,
  makeReplyBox,
  startEditComment,
  setAnnotationComment,
  buildPreviewEl,
} from './annotations'
import { getEditor } from './editor'

// ─── Undo/redo for sidecar-side action effects ─────────────────────────────
// CM6's own history already undoes text edits for free. Accept/reject/resolve/
// comment/reply also mutate the .folio sidecar outside CM6's document model —
// this makes that mutation ride along with the same undo/redo step via
// invertedEffects, confirmed (by reading @codemirror/commands' source) to
// record effect-only transactions (e.g. reject, which has no text change) in
// history as long as this provider returns a non-empty effect for them.

interface AnnotationActionPayload {
  id: string
  before: FolioAnnotation | undefined // undefined = didn't exist yet (comment creation)
  after: FolioAnnotation | undefined
}

const annotationActionEffect = StateEffect.define<AnnotationActionPayload>()

// Called again on the stored undo event when it's later pushed onto the redo
// branch, so this must invert in either direction — swapping before/after is
// its own inverse (an involution), which makes that automatic.
const annotationActionInverter = invertedEffects.of(tr =>
  tr.effects
    .filter((e): e is StateEffect<AnnotationActionPayload> => e.is(annotationActionEffect))
    .map(e => annotationActionEffect.of({ id: e.value.id, before: e.value.after, after: e.value.before })),
)

function applySidecarSnapshot(id: string, snapshot: FolioAnnotation | undefined, view: EditorView): void {
  const current = getSidecar()
  const exists = current.annotations.some(a => a.id === id)
  let annotations: FolioAnnotation[]
  if (snapshot === undefined) {
    annotations = current.annotations.filter(a => a.id !== id)
  } else if (exists) {
    annotations = current.annotations.map(a => (a.id === id ? snapshot : a))
  } else {
    annotations = [...current.annotations, snapshot]
  }
  const updated: Sidecar = { ...current, annotations }
  updateSidecar(updated)
  putFolio(updated)
  const tiptapEditor = getEditor()
  if (tiptapEditor) tiptapEditor.view.dispatch(tiptapEditor.state.tr)
  refreshRawAnnotations(view)
}

// Reacts only to undo/redo — the original "do" action already applied its
// mutation directly via resolveAnnotation/addCommentAnnotation/putFolio, so
// reacting unconditionally here would double-apply it.
function undoRedoListener(update: ViewUpdate): void {
  for (const tr of update.transactions) {
    if (!tr.isUserEvent('undo') && !tr.isUserEvent('redo')) continue
    for (const e of tr.effects) {
      if (e.is(annotationActionEffect)) {
        applySidecarSnapshot(e.value.id, e.value.after, update.view)
      }
    }
  }
}

// ─── Anchor bookkeeping ─────────────────────────────────────────────────────
// A maintained list of resolved positions, remapped through every transaction
// (mirrors Tiptap's plugin-state anchors map + tr.mapping). Kept separate from
// the decoration set below because zero-width `insert` anchors need a tracked
// position for gutter/accept purposes even though they render no visible mark.

interface RawAnchor {
  id: string
  from: number
  to: number
  kind: FolioAnnotation['kind']
}

let currentAnchors: RawAnchor[] = []

function getRawAnchor(id: string): { from: number; to: number } | undefined {
  return currentAnchors.find(a => a.id === id)
}

// ─── Decoration marks + preview widgets (visual only) ──────────────────────

const setAnnotationDecos = StateEffect.define<RawAnchor[]>()

// Reuses Tiptap's buildPreviewEl (annotations.ts) to render the suggested
// replacement/insertion text inline, exactly like Tiptap's own
// .ann-insert-preview/.ann-replace-preview widgets — those classes aren't
// scoped to .tiptap, so they render correctly here with no new CSS needed.
class PreviewWidget extends WidgetType {
  constructor(private ann: FolioAnnotation) {
    super()
  }
  eq(other: PreviewWidget): boolean {
    return other.ann.id === this.ann.id && other.ann.replacement === this.ann.replacement
  }
  toDOM(): HTMLElement {
    const tiptapEditor = getEditor()
    const el = tiptapEditor ? buildPreviewEl(this.ann.replacement ?? '', tiptapEditor) : document.createElement('span')
    el.addEventListener('mousedown', e => {
      e.stopPropagation()
      setFocused(this.ann.id)
    })
    return el
  }
}

function buildRawDecos(anchors: RawAnchor[]): Range<Decoration>[] {
  const byId = new Map(getSidecar().annotations.map(a => [a.id, a]))
  const decos: Range<Decoration>[] = []
  for (const anchor of anchors) {
    const ann = byId.get(anchor.id)
    if (!ann) continue
    const { from, to } = anchor
    switch (ann.kind) {
      case 'delete':
        decos.push(Decoration.mark({ class: 'cm-ann-delete' }).range(from, to))
        break
      case 'replace':
        decos.push(Decoration.mark({ class: 'cm-ann-delete' }).range(from, to))
        if (ann.replacement) {
          decos.push(Decoration.widget({ widget: new PreviewWidget(ann), side: 1 }).range(to))
        }
        break
      case 'insert':
        if (ann.replacement) {
          decos.push(Decoration.widget({ widget: new PreviewWidget(ann), side: -1 }).range(from))
        }
        break
      case 'highlight':
        decos.push(Decoration.mark({ class: 'cm-ann-highlight' }).range(from, to))
        break
      case 'comment':
        if (from !== to) decos.push(Decoration.mark({ class: 'cm-ann-comment-target' }).range(from, to))
        break
    }
  }
  return decos
}

const annotationField = StateField.define<DecorationSet>({
  create: () => Decoration.none,
  update(decos, tr) {
    decos = decos.map(tr.changes)
    for (const e of tr.effects) {
      if (e.is(setAnnotationDecos)) {
        decos = Decoration.set(buildRawDecos(e.value), true)
      }
    }
    return decos
  },
  provide: f => EditorView.decorations.from(f),
})

// ─── Floater/gutter DOM (built once, lazily) ───────────────────────────────

let wrapperEl: HTMLElement | null = null
let gutterEl: HTMLElement | null = null
let currentView: EditorView | null = null

let commentFloater: HTMLDivElement | null = null
let cfGutterForm: HTMLDivElement | null = null
let cfTextarea: HTMLTextAreaElement | null = null
let cfRefresh: (() => void) | null = null
let savedSelection: { from: number; to: number } | null = null

let formOverlayEl: HTMLDivElement | null = null

let overlayEl: HTMLDivElement | null = null
let overlaySig = ''
let focusedAnnotationId: string | null = null

function hideCommentForm(): void {
  if (commentFloater) commentFloater.hidden = true
  if (cfGutterForm) {
    cfGutterForm.hidden = true
    cfGutterForm.classList.remove('ann-overlay')
    if (gutterEl && cfGutterForm.parentElement !== gutterEl) gutterEl.appendChild(cfGutterForm)
  }
  if (formOverlayEl) formOverlayEl.hidden = true
  if (cfTextarea) {
    cfTextarea.value = ''
    cfTextarea.style.height = ''
    cfRefresh?.()
  }
  savedSelection = null
  if (gutterEl) repositionCards(gutterEl)
}

function updateFocusedCardClasses(): void {
  if (!gutterEl) return
  gutterEl.querySelectorAll<HTMLElement>('.ann-card').forEach(card => {
    card.classList.toggle('ann-card-focused', card.dataset.id === focusedAnnotationId)
  })
  repositionCards(gutterEl)
}

function hideOverlay(): void {
  if (!overlayEl) return
  overlayEl.hidden = true
  overlayEl.replaceChildren()
  overlaySig = ''
}

function updateOverlay(): void {
  if (!overlayEl || !wrapperEl || !currentView) return
  const ann = focusedAnnotationId
    ? getSidecar().annotations.find(a => a.id === focusedAnnotationId && !a.resolved)
    : null
  const anchor = ann ? getRawAnchor(ann.id) : null
  if (!ann || !anchor || document.getElementById('app')?.classList.contains('gutter-open')) {
    hideOverlay()
    return
  }
  const coords = currentView.coordsAtPos(anchor.from)
  if (!coords) {
    hideOverlay()
    return
  }
  // Rebuild only when the annotation changed, so a focused reply box survives.
  const sig = JSON.stringify(ann)
  if (sig !== overlaySig) {
    const hadFocus = overlayEl.contains(document.activeElement)
    const card = makeRawGutterCard(ann, currentView)
    card.classList.add('ann-overlay', 'ann-card-focused')
    overlayEl.replaceChildren(card)
    overlaySig = sig
    if (hadFocus) card.querySelector<HTMLTextAreaElement>('.ann-reply-textarea')?.focus()
  }
  const containerRect = wrapperEl.getBoundingClientRect()
  overlayEl.hidden = false
  const height = overlayEl.offsetHeight
  // Flip above the anchor when it won't fit below but will fit above.
  const flip = containerRect.bottom - coords.bottom < height + 12 && coords.top - containerRect.top > height + 12
  const top = flip
    ? coords.top - containerRect.top + wrapperEl.scrollTop - height - 6
    : coords.bottom - containerRect.top + wrapperEl.scrollTop + 6
  const maxLeft = wrapperEl.clientWidth - overlayEl.offsetWidth - 8
  const left = Math.max(8, Math.min(coords.left - containerRect.left, maxLeft))
  overlayEl.style.top = `${top}px`
  overlayEl.style.left = `${left}px`
  overlayEl.hidden = false
}

function positionFormOverlay(): void {
  if (!formOverlayEl || formOverlayEl.hidden || !wrapperEl || !currentView || !savedSelection) return
  const start = currentView.coordsAtPos(savedSelection.from)
  const end = currentView.coordsAtPos(savedSelection.to)
  if (!start || !end) {
    hideCommentForm()
    return
  }
  const containerRect = wrapperEl.getBoundingClientRect()
  const height = formOverlayEl.offsetHeight
  // Flip above the selection when it won't fit below but will fit above.
  const flip = containerRect.bottom - end.bottom < height + 12 && start.top - containerRect.top > height + 12
  const top = flip
    ? start.top - containerRect.top + wrapperEl.scrollTop - height - 6
    : end.bottom - containerRect.top + wrapperEl.scrollTop + 6
  const maxLeft = wrapperEl.clientWidth - formOverlayEl.offsetWidth - 8
  const left = Math.max(8, Math.min(start.left - containerRect.left, maxLeft))
  formOverlayEl.style.top = `${top}px`
  formOverlayEl.style.left = `${left}px`
}

function setFocused(id: string | null): void {
  if (focusedAnnotationId === id) return
  focusedAnnotationId = id
  updateOverlay()
  updateFocusedCardClasses()
}

function updateCommentFloaterPosition(view: EditorView): void {
  if (!commentFloater || !wrapperEl || !cfGutterForm) return
  if (!cfGutterForm.hidden) return // keep position stable while the form is active
  const sel = view.state.selection.main
  if (sel.empty) {
    commentFloater.hidden = true
    return
  }
  const containerRect = wrapperEl.getBoundingClientRect()
  const coordsFrom = view.coordsAtPos(sel.from)
  const coordsTo = view.coordsAtPos(sel.to)
  if (!coordsFrom || !coordsTo) {
    commentFloater.hidden = true
    return
  }
  const midX = (coordsFrom.left + coordsTo.right) / 2
  const top = coordsFrom.top - containerRect.top + wrapperEl.scrollTop
  const left = Math.max(80, Math.min(midX - containerRect.left, wrapperEl.clientWidth - 80))
  commentFloater.style.top = `${top}px`
  commentFloater.style.left = `${left}px`
  commentFloater.hidden = false
  savedSelection = { from: sel.from, to: sel.to }
}

function buildFloaterDOM(): void {
  if (commentFloater) return // idempotent — build once
  if (!wrapperEl || !gutterEl) return

  // ── Comment floater + inline form ──
  commentFloater = document.createElement('div')
  commentFloater.id = 'comment-floater'
  commentFloater.hidden = true
  wrapperEl.appendChild(commentFloater)

  const cfBtn = document.createElement('button')
  cfBtn.className = 'af-btn'
  cfBtn.textContent = 'Comment'
  commentFloater.appendChild(cfBtn)

  cfGutterForm = document.createElement('div')
  cfGutterForm.className = 'cf-gutter-form'
  cfGutterForm.hidden = true
  gutterEl.appendChild(cfGutterForm)

  const cfTitle = document.createElement('div')
  cfTitle.className = 'cf-title'
  cfTitle.textContent = 'New comment'
  cfGutterForm.appendChild(cfTitle)

  const { box: cfReplyBox, textarea, send: cfSubmitBtn, refresh } = makeReplyBox()
  cfTextarea = textarea
  cfRefresh = refresh
  cfTextarea.placeholder = 'Add a comment…'
  cfSubmitBtn.title = 'Add comment'
  cfTextarea.addEventListener('input', () => {
    cfTextarea!.style.height = 'auto'
    cfTextarea!.style.height = `${cfTextarea!.scrollHeight}px`
    if (gutterEl) repositionCards(gutterEl)
    positionFormOverlay()
  })
  cfGutterForm.appendChild(cfReplyBox)

  // Comment form shown next to the text when the comment pane is closed.
  formOverlayEl = document.createElement('div')
  formOverlayEl.id = 'comment-form-overlay'
  formOverlayEl.hidden = true
  wrapperEl.appendChild(formOverlayEl)

  document.addEventListener('keydown', e => {
    if (e.key !== 'Escape' || !cfGutterForm || cfGutterForm.hidden) return
    hideCommentForm()
    currentView?.focus()
  })
  document.addEventListener('mousedown', e => {
    if (!cfGutterForm || cfGutterForm.hidden) return
    const target = e.target as Node
    if (cfGutterForm.contains(target) || commentFloater?.contains(target)) return
    hideCommentForm()
  })

  cfBtn.addEventListener('mousedown', e => {
    e.preventDefault()
    if (!commentFloater || !cfGutterForm) return
    const top = commentFloater.style.top
    cfGutterForm.dataset.anchorTop = String(parseFloat(top || '0'))
    cfGutterForm.dataset.anchorFrom = String(savedSelection?.from ?? 0)
    cfGutterForm.style.top = top
    cfGutterForm.hidden = false
    commentFloater.hidden = true
    if (formOverlayEl && !document.getElementById('app')?.classList.contains('gutter-open')) {
      cfGutterForm.classList.add('ann-overlay')
      formOverlayEl.appendChild(cfGutterForm)
      formOverlayEl.hidden = false
      positionFormOverlay()
    }
    if (gutterEl) repositionCards(gutterEl)
    cfTextarea?.focus()
  })

  cfTextarea.addEventListener('keydown', e => {
    if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
      e.preventDefault()
      cfSubmitBtn.dispatchEvent(new MouseEvent('mousedown'))
    }
  })

  cfSubmitBtn.addEventListener('mousedown', e => {
    e.preventDefault()
    const comment = cfTextarea!.value.trim()
    if (!comment || !savedSelection || !currentView) {
      hideCommentForm()
      return
    }
    const { from, to } = savedSelection
    const docStr = currentView.state.doc.toString()
    const target = docStr.slice(from, to)
    const contextBefore = docStr.slice(Math.max(0, from - 30), from)
    const tiptapEditor = getEditor()
    if (tiptapEditor) {
      const after = addCommentAnnotation(contextBefore, target, comment, tiptapEditor)
      currentView.dispatch({
        effects: [annotationActionEffect.of({ id: after.id, before: undefined, after })],
        annotations: isolateHistory.of('full'),
      })
    }
    hideCommentForm()
    refreshRawAnnotations(currentView)
  })

  // ── Clicked-annotation overlay (comment pane closed) ──
  overlayEl = document.createElement('div')
  overlayEl.id = 'annotation-overlay'
  overlayEl.hidden = true
  wrapperEl.appendChild(overlayEl)

  document.addEventListener('keydown', e => {
    if (e.key !== 'Escape' || !overlayEl || overlayEl.hidden) return
    setFocused(null)
    currentView?.focus()
  })
  document.addEventListener('mousedown', e => {
    if (!overlayEl || overlayEl.hidden || !currentView) return
    const target = e.target as Node
    if (overlayEl.contains(target) || currentView.dom.contains(target)) return
    setFocused(null)
  })
  window.addEventListener('folio:gutter-toggled', updateOverlay)
}

// ─── Accept / reply mutations (raw-text-specific) ──────────────────────────

function applyAcceptRaw(ann: FolioAnnotation, view: EditorView): void {
  const anchor = getRawAnchor(ann.id)
  let changes: { from: number; to: number; insert: string } | undefined
  if (anchor) {
    const { from, to } = anchor
    if (ann.kind === 'replace') {
      changes = { from, to, insert: ann.replacement ?? '' }
    } else if (ann.kind === 'delete') {
      changes = { from, to, insert: '' }
    } else if (ann.kind === 'insert') {
      changes = { from, to: from, insert: ann.replacement ?? '' }
    }
  }
  const tiptapEditor = getEditor()
  const after = tiptapEditor ? resolveAnnotation(ann, 'accepted', tiptapEditor) : ann
  view.dispatch({
    ...(changes ? { changes } : {}),
    effects: [annotationActionEffect.of({ id: ann.id, before: ann, after })],
    annotations: isolateHistory.of('full'),
  })
  putFile(view.state.doc.toString())
  refreshRawAnnotations(view)
}

function submitReplyRaw(ann: FolioAnnotation, body: string, view: EditorView): void {
  const trimmed = body.trim()
  if (!trimmed) return
  const reply: ThreadReply = {
    id: `reply-${Date.now()}`,
    author: 'me',
    source: 'local',
    body: trimmed,
    created: new Date().toISOString(),
  }
  const current = getSidecar()
  const before = current.annotations.find(a => a.id === ann.id)
  if (!before) return
  const after: FolioAnnotation = { ...before, replies: [...(before.replies ?? []), reply] }
  const updated: Sidecar = {
    ...current,
    annotations: current.annotations.map(a => (a.id === ann.id ? after : a)),
  }
  updateSidecar(updated)
  putFolio(updated)
  const tiptapEditor = getEditor()
  if (tiptapEditor) tiptapEditor.view.dispatch(tiptapEditor.state.tr)
  view.dispatch({
    effects: [annotationActionEffect.of({ id: ann.id, before, after })],
    annotations: isolateHistory.of('full'),
  })
  buildRawGutterCards(view)
}

// ─── Gutter cards ───────────────────────────────────────────────────────────

function makeRawGutterCard(ann: FolioAnnotation, view: EditorView): HTMLElement {
  const card = document.createElement('div')
  card.className = 'ann-card'
  card.dataset.source = ann.source
  card.dataset.id = ann.id

  const tiptapEditor = getEditor()
  const dispatchAction = (before: FolioAnnotation, after: FolioAnnotation) => {
    view.dispatch({
      effects: [annotationActionEffect.of({ id: ann.id, before, after })],
      annotations: isolateHistory.of('full'),
    })
  }
  const header = makeHeader(ann, {
    accept: () => {
      if (ann.kind !== 'comment') { applyAcceptRaw(ann, view); return }
      const t = getEditor()
      if (!t) return
      dispatchAction(ann, resolveAnnotation(ann, 'dismissed', t))
      refreshRawAnnotations(view)
    },
    remove: () => {
      const t = getEditor()
      if (!t) return
      dispatchAction(ann, resolveAnnotation(ann, ann.kind === 'comment' ? 'dismissed' : 'rejected', t))
      refreshRawAnnotations(view)
    },
    edit: (c, g) => startEditComment(c, ann, g, text => {
      setAnnotationComment(ann.id, text)
      const t = getEditor()
      if (t) t.view.dispatch(t.state.tr)
      dispatchAction(ann, { ...ann, comment: text })
      buildRawGutterCards(view)
    }),
  }, gutterEl)
  card.appendChild(buildThread(ann, header, tiptapEditor))

  const { box: actions, textarea, send } = makeReplyBox()
  textarea.addEventListener('input', () => {
    textarea.style.height = 'auto'
    textarea.style.height = `${textarea.scrollHeight}px`
    if (gutterEl) repositionCards(gutterEl)
  })

  const doSubmitReply = () => {
    submitReplyRaw(ann, textarea.value, view)
    textarea.value = ''
    textarea.style.height = ''
    send.classList.remove('ready')
  }

  textarea.addEventListener('keydown', e => {
    if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
      e.preventDefault()
      doSubmitReply()
    }
  })

  send.addEventListener('mousedown', e => {
    e.preventDefault()
    doSubmitReply()
  })

  card.appendChild(actions)

  card.addEventListener('mousedown', e => {
    if ((e.target as HTMLElement).closest('.ann-card-actions')) return
    e.preventDefault()
    setFocused(ann.id)
    textarea.focus()
  })

  return card
}

// Converts a document position to a #raw-editor-wrapper-relative top offset,
// without requiring the position to currently be rendered. CM6 virtualizes
// long documents — coordsAtPos returns null for anything scrolled out of the
// rendered window, which would otherwise mark perfectly-anchored annotations
// as "unanchored" just because they're off-screen when the gutter rebuilds.
// lineBlockAt gives a document-relative top for ANY position regardless of
// virtualization; view.viewport.from is always rendered, so it's used as a
// stable calibration point to convert that into wrapper-relative pixels.
function wrapperTopForDocPos(view: EditorView, pos: number): number | null {
  if (!wrapperEl) return null
  const refPos = view.viewport.from
  const refCoords = view.coordsAtPos(refPos)
  if (!refCoords) return null
  const viewportTopForDocZero = refCoords.top - view.lineBlockAt(refPos).top
  const wrapperRect = wrapperEl.getBoundingClientRect()
  return viewportTopForDocZero + view.lineBlockAt(pos).top - wrapperRect.top + wrapperEl.scrollTop
}

function buildRawGutterCards(view: EditorView): void {
  if (!gutterEl) return
  for (const el of gutterEl.querySelectorAll('.ann-card')) el.remove()

  const pending = getSidecar().annotations.filter(a => !a.resolved)
  if (pending.length === 0) {
    gutterEl.style.minHeight = `${view.contentHeight}px`
    return
  }

  for (const ann of pending) {
    const anchor = getRawAnchor(ann.id)
    const card = makeRawGutterCard(ann, view)
    const top = anchor ? wrapperTopForDocPos(view, anchor.from) : null
    if (anchor && top != null) {
      card.dataset.anchorTop = String(top)
      card.dataset.anchorFrom = String(anchor.from)
    } else {
      // Sort after every anchored card and park at the end of the document.
      card.classList.add('ann-card-unanchored')
      card.dataset.anchorTop = String(view.contentHeight)
      card.dataset.anchorFrom = String(Number.MAX_SAFE_INTEGER)
    }
    gutterEl.appendChild(card)
  }
  updateFocusedCardClasses()
}

// ─── Click-to-focus ─────────────────────────────────────────────────────────

function handleRawMousedown(event: MouseEvent, view: EditorView): boolean {
  const pos = view.posAtCoords({ x: event.clientX, y: event.clientY })
  if (pos == null) return false
  const found = currentAnchors.find(a => pos >= a.from && pos <= a.to)
  setFocused(found ? found.id : null)
  return false
}

function rawUpdateListener(update: ViewUpdate): void {
  if (update.docChanged) {
    currentAnchors = currentAnchors.map(a => ({
      ...a,
      from: update.changes.mapPos(a.from),
      to: update.changes.mapPos(a.to),
    }))
  }
  if (update.selectionSet) {
    updateCommentFloaterPosition(update.view)
  }
}

// ─── Public API ─────────────────────────────────────────────────────────────

export function rawAnnotationExtensions(): Extension[] {
  return [
    annotationField,
    EditorView.domEventHandlers({ mousedown: handleRawMousedown }),
    EditorView.updateListener.of(rawUpdateListener),
    annotationActionInverter,
    EditorView.updateListener.of(undoRedoListener),
  ]
}

export function mountRawGutter(view: EditorView, wrapper: HTMLElement, gutter: HTMLElement): void {
  currentView = view
  wrapperEl = wrapper
  gutterEl = gutter
  buildFloaterDOM()
}

export function setGutterHidden(hidden: boolean): void {
  if (gutterEl) gutterEl.hidden = hidden
}

export function refreshRawAnnotations(view: EditorView): void {
  const pending = getSidecar().annotations.filter(a => !a.resolved)
  if (pending.length === 0) {
    currentAnchors = []
    view.dispatch({ effects: setAnnotationDecos.of([]) })
    buildRawGutterCards(view)
    return
  }
  const items = pending.map(a => ({ id: a.id, context_before: a.context_before, target: a.target ?? undefined }))
  postAnchorRaw(items).then(results => {
    const byId = new Map(results.map(r => [r.id, r]))
    const anchors: RawAnchor[] = []
    for (const ann of pending) {
      const r = byId.get(ann.id)
      if (r?.char_from != null && r?.char_to != null) {
        anchors.push({ id: ann.id, from: r.char_from, to: r.char_to, kind: ann.kind })
      }
    }
    currentAnchors = anchors
    view.dispatch({ effects: setAnnotationDecos.of(anchors) })
    buildRawGutterCards(view)
  })
}
