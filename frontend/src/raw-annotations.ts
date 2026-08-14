import { StateField, StateEffect } from '@codemirror/state'
import type { Extension, Range } from '@codemirror/state'
import { EditorView, Decoration, WidgetType } from '@codemirror/view'
import type { DecorationSet, ViewUpdate } from '@codemirror/view'
import type { Annotation as FolioAnnotation, Sidecar, ThreadReply } from './api'
import { postAnchorRaw, putFolio, putFile } from './api'
import {
  getSidecar,
  resolveAnnotation,
  addCommentAnnotation,
  repositionCards,
  makeHeader,
  formatBody,
  formatTime,
  renderMarkdownContent,
  buildPreviewEl,
} from './annotations'
import { getEditor } from './editor'

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
let savedSelection: { from: number; to: number } | null = null

let actionFloater: HTMLDivElement | null = null
let focusedAnnotationId: string | null = null

function hideCommentForm(): void {
  if (commentFloater) commentFloater.hidden = true
  if (cfGutterForm) cfGutterForm.hidden = true
  if (cfTextarea) {
    cfTextarea.value = ''
    cfTextarea.style.height = ''
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

function updateActionFloaterPosition(): void {
  if (!actionFloater || !wrapperEl || !currentView) return
  const ann = focusedAnnotationId
    ? getSidecar().annotations.find(a => a.id === focusedAnnotationId && a.kind !== 'comment' && !a.resolved)
    : null
  const anchor = ann ? getRawAnchor(ann.id) : null
  if (!ann || !anchor) {
    actionFloater.hidden = true
    return
  }
  const containerRect = wrapperEl.getBoundingClientRect()
  const coordsFrom = currentView.coordsAtPos(anchor.from)
  const coordsTo = currentView.coordsAtPos(anchor.to)
  if (!coordsFrom || !coordsTo) {
    actionFloater.hidden = true
    return
  }
  const midX = (coordsFrom.left + coordsTo.right) / 2
  const top = coordsFrom.top - containerRect.top + wrapperEl.scrollTop
  const left = Math.max(80, Math.min(midX - containerRect.left, wrapperEl.clientWidth - 80))
  actionFloater.style.top = `${top}px`
  actionFloater.style.left = `${left}px`
  actionFloater.hidden = false
}

function setFocused(id: string | null): void {
  if (focusedAnnotationId === id) return
  focusedAnnotationId = id
  updateActionFloaterPosition()
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

  cfTextarea = document.createElement('textarea')
  cfTextarea.className = 'ann-reply-textarea'
  cfTextarea.placeholder = 'Add a comment…'
  cfTextarea.rows = 1
  cfTextarea.addEventListener('input', () => {
    cfTextarea!.style.height = 'auto'
    cfTextarea!.style.height = `${cfTextarea!.scrollHeight}px`
    if (gutterEl) repositionCards(gutterEl)
  })
  cfGutterForm.appendChild(cfTextarea)

  const cfActions = document.createElement('div')
  cfActions.className = 'ann-card-action-row'
  const cfSubmitBtn = document.createElement('button')
  cfSubmitBtn.className = 'ann-card-btn ann-card-reply'
  cfSubmitBtn.textContent = 'Add'
  const cfCancel = document.createElement('button')
  cfCancel.className = 'cf-cancel'
  cfCancel.textContent = 'Cancel'
  cfActions.appendChild(cfSubmitBtn)
  cfActions.appendChild(cfCancel)
  cfGutterForm.appendChild(cfActions)

  cfBtn.addEventListener('mousedown', e => {
    e.preventDefault()
    if (!commentFloater || !cfGutterForm) return
    const top = commentFloater.style.top
    cfGutterForm.dataset.anchorTop = String(parseFloat(top || '0'))
    cfGutterForm.dataset.anchorFrom = String(savedSelection?.from ?? 0)
    cfGutterForm.style.top = top
    cfGutterForm.hidden = false
    commentFloater.hidden = true
    if (gutterEl) repositionCards(gutterEl)
    cfTextarea?.focus()
  })

  cfCancel.addEventListener('mousedown', e => {
    e.preventDefault()
    hideCommentForm()
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
    if (tiptapEditor) addCommentAnnotation(contextBefore, target, comment, tiptapEditor)
    hideCommentForm()
    refreshRawAnnotations(currentView)
  })

  // ── Action floater (Accept/Reject) ──
  actionFloater = document.createElement('div')
  actionFloater.id = 'action-floater'
  actionFloater.hidden = true
  wrapperEl.appendChild(actionFloater)

  const afAccept = document.createElement('button')
  afAccept.className = 'af-btn'
  afAccept.textContent = 'Accept'
  afAccept.addEventListener('mousedown', e => {
    e.preventDefault()
    const ann = focusedAnnotationId ? getSidecar().annotations.find(a => a.id === focusedAnnotationId) : null
    if (ann && currentView) applyAcceptRaw(ann, currentView)
  })

  const afDivider = document.createElement('span')
  afDivider.className = 'af-divider'

  const afReject = document.createElement('button')
  afReject.className = 'af-btn'
  afReject.textContent = 'Reject'
  afReject.addEventListener('mousedown', e => {
    e.preventDefault()
    const ann = focusedAnnotationId ? getSidecar().annotations.find(a => a.id === focusedAnnotationId) : null
    const tiptapEditor = getEditor()
    if (ann && tiptapEditor && currentView) {
      resolveAnnotation(ann, 'rejected', tiptapEditor)
      refreshRawAnnotations(currentView)
    }
  })

  actionFloater.appendChild(afAccept)
  actionFloater.appendChild(afDivider)
  actionFloater.appendChild(afReject)
}

// ─── Accept / reply mutations (raw-text-specific) ──────────────────────────

function applyAcceptRaw(ann: FolioAnnotation, view: EditorView): void {
  const anchor = getRawAnchor(ann.id)
  if (anchor) {
    const { from, to } = anchor
    if (ann.kind === 'replace') {
      view.dispatch({ changes: { from, to, insert: ann.replacement ?? '' } })
    } else if (ann.kind === 'delete') {
      view.dispatch({ changes: { from, to, insert: '' } })
    } else if (ann.kind === 'insert') {
      view.dispatch({ changes: { from, to: from, insert: ann.replacement ?? '' } })
    }
  }
  const tiptapEditor = getEditor()
  if (tiptapEditor) resolveAnnotation(ann, 'accepted', tiptapEditor)
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
  const updated: Sidecar = {
    ...current,
    annotations: current.annotations.map(a => (a.id === ann.id ? { ...a, replies: [...(a.replies ?? []), reply] } : a)),
  }
  putFolio(updated)
  const tiptapEditor = getEditor()
  if (tiptapEditor) tiptapEditor.view.dispatch(tiptapEditor.state.tr)
  buildRawGutterCards(view)
}

// ─── Gutter cards ───────────────────────────────────────────────────────────

function makeRawGutterCard(ann: FolioAnnotation, view: EditorView): HTMLElement {
  const card = document.createElement('div')
  card.className = 'ann-card'
  card.dataset.source = ann.source
  card.dataset.id = ann.id

  const tiptapEditor = getEditor()
  card.appendChild(makeHeader(ann))

  if (ann.kind === 'comment') {
    const body = document.createElement('div')
    body.className = 'ann-card-body'
    if (tiptapEditor) body.appendChild(renderMarkdownContent(ann.comment ?? '', tiptapEditor))
    card.appendChild(body)
  } else {
    const body = document.createElement('div')
    body.className = 'ann-card-body'
    body.textContent = formatBody(ann)
    card.appendChild(body)

    if (ann.comment && tiptapEditor) {
      const commentEl = document.createElement('div')
      commentEl.className = 'ann-card-comment'
      commentEl.appendChild(renderMarkdownContent(ann.comment, tiptapEditor))
      card.appendChild(commentEl)
    }
  }

  if ((ann.replies ?? []).length > 0 && tiptapEditor) {
    const repliesSection = document.createElement('div')
    repliesSection.className = 'ann-card-replies'
    for (const reply of ann.replies!) {
      const replyEl = document.createElement('div')
      replyEl.className = 'ann-reply'
      const replyHeader = document.createElement('div')
      replyHeader.className = 'ann-reply-header'
      const replyAuthor = document.createElement('strong')
      replyAuthor.className = 'ann-reply-author'
      replyAuthor.textContent = reply.author
      const replyTime = document.createElement('span')
      replyTime.className = 'ann-reply-time'
      replyTime.textContent = formatTime(reply.created)
      replyHeader.appendChild(replyAuthor)
      replyHeader.appendChild(replyTime)
      const replyBody = document.createElement('div')
      replyBody.className = 'ann-reply-body'
      replyBody.appendChild(renderMarkdownContent(reply.body, tiptapEditor))
      replyEl.appendChild(replyHeader)
      replyEl.appendChild(replyBody)
      repliesSection.appendChild(replyEl)
    }
    card.appendChild(repliesSection)
  }

  const actions = document.createElement('div')
  actions.className = 'ann-card-actions'

  const textarea = document.createElement('textarea')
  textarea.className = 'ann-reply-textarea'
  textarea.placeholder = 'Reply…'
  textarea.rows = 1
  textarea.addEventListener('input', () => {
    textarea.style.height = 'auto'
    textarea.style.height = `${textarea.scrollHeight}px`
    if (gutterEl) repositionCards(gutterEl)
  })
  actions.appendChild(textarea)

  const btnRow = document.createElement('div')
  btnRow.className = 'ann-card-action-row'

  const doSubmitReply = () => {
    submitReplyRaw(ann, textarea.value, view)
    textarea.value = ''
    textarea.style.height = ''
  }

  textarea.addEventListener('keydown', e => {
    if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
      e.preventDefault()
      doSubmitReply()
    }
  })

  if (ann.kind === 'comment') {
    const dismiss = document.createElement('button')
    dismiss.className = 'ann-card-btn ann-card-dismiss'
    dismiss.textContent = 'Resolve'
    dismiss.addEventListener('mousedown', e => {
      e.preventDefault()
      const t = getEditor()
      if (t) {
        resolveAnnotation(ann, 'dismissed', t)
        refreshRawAnnotations(view)
      }
    })
    btnRow.appendChild(dismiss)
  }

  const replyBtn = document.createElement('button')
  replyBtn.className = 'ann-card-btn ann-card-reply'
  replyBtn.textContent = 'Reply'
  replyBtn.addEventListener('mousedown', e => {
    e.preventDefault()
    doSubmitReply()
  })
  btnRow.appendChild(replyBtn)

  actions.appendChild(btnRow)
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
    if (anchor) {
      const top = wrapperTopForDocPos(view, anchor.from)
      if (top != null) {
        card.dataset.anchorTop = String(top)
      } else {
        card.classList.add('ann-card-unanchored')
      }
    } else {
      card.classList.add('ann-card-unanchored')
    }
    card.dataset.anchorFrom = String(anchor?.from ?? 0)
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
  ]
}

export function mountRawGutter(view: EditorView, wrapper: HTMLElement, gutter: HTMLElement): void {
  currentView = view
  wrapperEl = wrapper
  gutterEl = gutter
  buildFloaterDOM()
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
