import { Extension } from '@tiptap/core'
import type { Editor, JSONContent } from '@tiptap/core'
import { Plugin, PluginKey, TextSelection } from '@tiptap/pm/state'
import { undoDepth } from '@tiptap/pm/history'
import { Decoration, DecorationSet } from '@tiptap/pm/view'
import { DOMSerializer, Node as PMNode } from '@tiptap/pm/model'
import type { EditorView } from '@tiptap/pm/view'
import type { Annotation, Sidecar, ThreadReply } from './api'
import { putFolio, postAnchor, postAccept } from './api'
import { flushSave } from './editor'

// ─── Sidecar state ───────────────────────────────────────────────────────────

let currentSidecar: Sidecar = { version: 1, annotations: [] }
let sidecarUpdateCb: (() => void) | null = null

// ─── Annotation undo stack ───────────────────────────────────────────────────
// Simple stack for sidecar-only actions (reject/dismiss) that don't produce a
// ProseMirror doc-history entry of their own to hang undo off of.

let annotationKeyboardUndoStack: Array<{ snapshot: Annotation[]; pmDepth: number }> = []

// ─── Reply draft state ───────────────────────────────────────────────────────

const replyDrafts = new Map<string, string>()

// ─── Focus state ─────────────────────────────────────────────────────────────

let focusedAnnotationId: string | null = null
let shouldFocusReply = false
let currentGutterEl: HTMLElement | null = null
let focusChangeCallback: (() => void) | null = null
let rebuildFn: (() => void) | null = null
let pendingCommentRange: { from: number; to: number } | null = null

export function scheduleGutterRebuild(): void {
  if (rebuildFn) requestAnimationFrame(rebuildFn)
}

export function setGutterHidden(hidden: boolean): void {
  if (currentGutterEl) currentGutterEl.hidden = hidden
}

function updateFocusedCard(): void {
  if (!currentGutterEl) return
  currentGutterEl.querySelectorAll<HTMLElement>('.ann-card').forEach(card => {
    card.classList.toggle('ann-card-focused', card.dataset.id === focusedAnnotationId)
  })
  repositionCards(currentGutterEl)
  focusChangeCallback?.()
}

// Returns true when the incoming sidecar is an echo of what we last wrote
// (i.e. a WebSocket round-trip of our own PUT). On echo, undo stacks are left
// intact; on genuine external updates they are cleared.
export function updateSidecar(sidecar: Sidecar): boolean {
  const isEcho = JSON.stringify(sidecar) === JSON.stringify(currentSidecar)
  currentSidecar = sidecar
  if (isEcho) return true
  annotationKeyboardUndoStack = []
  replyDrafts.clear()
  return false
}

export function getSidecar(): Sidecar {
  return currentSidecar
}

export function onSidecarUpdate(cb: () => void): void {
  sidecarUpdateCb = cb
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

// Build a map from each character's index in the document's rendered plain text
// to its ProseMirror position. Used to convert server-returned char indices to
// PM positions for decorations.
export function buildCharPos(doc: PMNode): number[] {
  const charPos: number[] = []
  doc.descendants((node, pos) => {
    // Skip code block content — strip_markdown skips fenced blocks too,
    // so both sides must agree on what counts as rendered text.
    if (node.type.name === 'codeBlock') return false
    if (node.isText) {
      for (let i = 0; i < node.text!.length; i++) {
        charPos.push(pos + i)
      }
    }
  })
  return charPos
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

// ─── Helpers ─────────────────────────────────────────────────────────────────

export function resolveAnnotation(ann: Annotation, as: string, editor: Editor): Annotation {
  const resolved: Annotation = { ...ann, resolved: true, resolved_as: as, resolved_at: new Date().toISOString() }
  const updated: Sidecar = {
    ...currentSidecar,
    annotations: currentSidecar.annotations.map(a => (a.id === ann.id ? resolved : a)),
  }
  currentSidecar = updated
  putFolio(updated)
  sidecarUpdateCb?.()
  // Remove this annotation from the plugin's anchors map; remaining positions
  // were already updated via tr.mapping when the doc-change transaction ran.
  editor.view.dispatch(editor.state.tr.setMeta(annotationsKey, { type: 'resolve', id: ann.id }))
  return resolved
}

export function addCommentAnnotation(contextBefore: string, target: string, comment: string, editor: Editor): Annotation {
  const ann: Annotation = {
    id: `ann-${Date.now()}`,
    kind: 'comment',
    source: 'local',
    author: 'me',
    context_before: contextBefore,
    target,
    comment,
    created: new Date().toISOString(),
    resolved: false,
  }
  const updated: Sidecar = {
    ...currentSidecar,
    annotations: [...currentSidecar.annotations, ann],
  }
  currentSidecar = updated
  putFolio(updated)
  sidecarUpdateCb?.()
  // New annotation needs to be anchored from scratch.
  editor.view.dispatch(editor.state.tr.setMeta(annotationsKey, { type: 'sidecar-updated' }))
  return ann
}

// Accepting edits the markdown, so the server applies it to the file and
// broadcasts md:changed + folio:changed; the editor reloads from those events.
// Pending preview edits are saved first so the server patches the current text.
function acceptAnnotation(id: string): void {
  void flushSave()
    .then(() => postAccept(id))
    .then(r => { if (!r.ok) return r.text().then(msg => console.error(`Accept failed: ${msg}`)) })
    .catch(console.error)
}

// ─── Annotation keyboard navigation ─────────────────────────────────────────

function navigateAnnotation(direction: 1 | -1, view: EditorView): boolean {
  const pending = currentSidecar.annotations.filter(a => !a.resolved)
  if (pending.length === 0) return false

  const pluginAnchors = annotationsKey.getState(view.state)?.anchors
  const sorted: Array<{ ann: Annotation; from: number }> = []
  for (const ann of pending) {
    const anchor = pluginAnchors?.get(ann.id)
    if (anchor) sorted.push({ ann, from: anchor.from })
  }
  sorted.sort((a, b) => a.from - b.from)
  if (sorted.length === 0) return false

  const currentIdx = sorted.findIndex(e => e.ann.id === focusedAnnotationId)
  const nextIdx =
    currentIdx === -1
      ? direction === 1 ? 0 : sorted.length - 1
      : (currentIdx + direction + sorted.length) % sorted.length

  const { ann, from } = sorted[nextIdx]
  focusedAnnotationId = ann.id
  updateFocusedCard()

  view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, from)))
  view.focus()

  requestAnimationFrame(() => {
    currentGutterEl
      ?.querySelector<HTMLElement>(`[data-id="${ann.id}"]`)
      ?.scrollIntoView({ block: 'nearest', behavior: 'smooth' })
  })

  return true
}

// ─── Inline decorations ───────────────────────────────────────────────────────

export function renderMarkdownContent(markdown: string, editor: Editor): Node {
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

export function buildPreviewEl(replacement: string, editor: Editor): HTMLElement {
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
            Decoration.widget(
              to,
              () => {
                const el = buildPreviewEl(ann.replacement!, editor)
                el.addEventListener('mousedown', e => {
                  e.stopPropagation()
                  focusedAnnotationId = ann.id
                  updateFocusedCard()
                })
                return el
              },
              { side: 1, key: `${ann.id}-preview` },
            ),
          )
        }
        break
      case 'insert':
        if (ann.replacement) {
          decos.push(
            Decoration.widget(
              from,
              () => {
                const el = buildPreviewEl(ann.replacement!, editor)
                el.addEventListener('mousedown', e => {
                  e.stopPropagation()
                  focusedAnnotationId = ann.id
                  updateFocusedCard()
                })
                return el
              },
              { side: -1, key: `${ann.id}-preview` },
            ),
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

// ─── Gutter cards ─────────────────────────────────────────────────────────────

export function formatBody(ann: Annotation): string {
  const t = (s: string, max = 60) => {
    const flat = s.replace(/\n/g, ' ')
    return flat.length > max ? flat.slice(0, max) + '…' : flat
  }
  switch (ann.kind) {
    case 'replace':
      return `"${t(ann.target ?? '')}" → "${t(ann.replacement ?? '')}"`
    case 'delete':
      return `"${t(ann.target ?? '')}"`
    case 'insert':
      return `"${t(ann.replacement ?? '')}"`
    case 'highlight':
      return `"${t(ann.target ?? '')}"`
    case 'comment':
      return t(ann.comment ?? '', 32)
  }
}

export function formatTime(iso: string): string {
  return new Date(iso).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
}

export interface HeaderActions {
  accept: () => void
  remove: () => void
  edit: (card: HTMLElement, gutterEl: HTMLElement | null) => void
}

function makeMenuItem(label: string, danger: boolean, onClick: () => void): HTMLButtonElement {
  const item = document.createElement('button')
  item.className = 'ann-card-menu-item' + (danger ? ' ann-card-menu-danger' : '')
  item.textContent = label
  item.addEventListener('mousedown', e => {
    e.preventDefault()
    e.stopPropagation()
    onClick()
  })
  return item
}

export function makeHeader(ann: Annotation, actions?: HeaderActions, gutterEl: HTMLElement | null = null): HTMLElement {
  const header = document.createElement('div')
  header.className = 'ann-card-header'
  const author = document.createElement('strong')
  author.className = 'ann-card-author'
  author.textContent = displayName(ann.author)
  const time = document.createElement('span')
  time.className = 'ann-card-time'
  time.textContent = formatTime(ann.created)
  header.appendChild(author)
  header.appendChild(time)
  if (!actions) return header

  const group = document.createElement('div')
  group.className = 'ann-card-header-actions'

  const accept = document.createElement('button')
  accept.className = 'ann-card-icon-btn'
  accept.title = ann.kind === 'comment' ? 'Resolve' : 'Accept'
  accept.textContent = '✓'
  accept.addEventListener('mousedown', e => {
    e.preventDefault()
    e.stopPropagation()
    actions.accept()
  })

  const more = document.createElement('button')
  more.className = 'ann-card-icon-btn'
  more.title = 'More'
  more.innerHTML = '<svg width="14" height="14" viewBox="0 0 14 14" fill="currentColor"><circle cx="2.5" cy="7" r="1.2"/><circle cx="7" cy="7" r="1.2"/><circle cx="11.5" cy="7" r="1.2"/></svg>'

  const menu = document.createElement('div')
  menu.className = 'ann-card-menu'
  menu.hidden = true

  const closeMenu = () => {
    menu.hidden = true
    document.removeEventListener('mousedown', closeMenu)
  }
  menu.appendChild(makeMenuItem('Edit comment', false, () => {
    closeMenu()
    actions.edit(header.closest('.ann-card') as HTMLElement, gutterEl)
  }))
  menu.appendChild(makeMenuItem('Delete', true, () => {
    closeMenu()
    actions.remove()
  }))
  more.addEventListener('mousedown', e => {
    e.preventDefault()
    e.stopPropagation()
    if (!menu.hidden) { closeMenu(); return }
    menu.hidden = false
    document.addEventListener('mousedown', closeMenu)
  })

  group.appendChild(accept)
  group.appendChild(more)
  group.appendChild(menu)
  header.appendChild(group)
  return header
}

// Swaps the card's comment text for an inline textarea. `onSave` persists the new text.
export function startEditComment(
  card: HTMLElement,
  ann: Annotation,
  gutterEl: HTMLElement | null,
  onSave: (text: string) => void,
): void {
  if (card.querySelector('.ann-edit-textarea')) return
  const existing = card.querySelector<HTMLElement>(ann.kind === 'comment' ? '.ann-card-body' : '.ann-card-comment')

  const wrap = document.createElement('div')
  wrap.className = 'ann-edit'
  const textarea = document.createElement('textarea')
  textarea.className = 'ann-reply-textarea ann-edit-textarea'
  textarea.value = ann.comment ?? ''
  const resize = () => {
    textarea.style.height = 'auto'
    textarea.style.height = `${textarea.scrollHeight}px`
    if (gutterEl) repositionCards(gutterEl)
  }
  textarea.addEventListener('input', resize)

  const row = document.createElement('div')
  row.className = 'ann-card-action-row'
  const cancel = document.createElement('button')
  cancel.className = 'ann-card-btn ann-card-dismiss'
  cancel.textContent = 'Cancel'
  const save = document.createElement('button')
  save.className = 'ann-card-btn ann-card-reply'
  save.textContent = 'Save'
  row.appendChild(cancel)
  row.appendChild(save)
  wrap.appendChild(textarea)
  wrap.appendChild(row)

  const close = () => {
    wrap.remove()
    if (existing) existing.hidden = false
    if (gutterEl) repositionCards(gutterEl)
  }
  cancel.addEventListener('mousedown', e => { e.preventDefault(); close() })
  save.addEventListener('mousedown', e => {
    e.preventDefault()
    onSave(textarea.value.trim())
  })
  textarea.addEventListener('keydown', e => {
    if (e.key === 'Escape') { e.preventDefault(); close() }
    if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); onSave(textarea.value.trim()) }
  })
  wrap.addEventListener('mousedown', e => e.stopPropagation())

  if (existing) {
    existing.hidden = true
    existing.after(wrap)
  } else {
    card.querySelector('.ann-card-body')!.after(wrap)
  }
  resize()
  textarea.focus()
}

export function setAnnotationComment(id: string, comment: string): void {
  currentSidecar = {
    ...currentSidecar,
    annotations: currentSidecar.annotations.map(a => (a.id === id ? { ...a, comment } : a)),
  }
  putFolio(currentSidecar)
  sidecarUpdateCb?.()
}

const AVATAR_COLORS = ['#6366f1', '#0891b2', '#db2777', '#7c3aed']

export function displayName(author: string): string {
  return author === 'me' ? 'You' : author
}

function makeAvatar(name: string): HTMLElement {
  const el = document.createElement('div')
  el.className = 'ann-avatar'
  const words = name.trim().split(/\s+/).filter(Boolean)
  el.textContent = name === 'You' ? 'Y' : (words.length > 1 ? words[0][0] + words[1][0] : name.slice(0, 2)).toUpperCase()
  let hash = 0
  for (const ch of name) hash = (hash * 31 + ch.charCodeAt(0)) >>> 0
  el.style.background = name === 'You' ? AVATAR_COLORS[0] : AVATAR_COLORS[1 + (hash % (AVATAR_COLORS.length - 1))]
  return el
}

function makeEntry(name: string, header: HTMLElement, bodies: HTMLElement[]): HTMLElement {
  const entry = document.createElement('div')
  entry.className = 'ann-entry'
  const main = document.createElement('div')
  main.className = 'ann-entry-main'
  main.appendChild(header)
  for (const b of bodies) main.appendChild(b)
  entry.appendChild(makeAvatar(name))
  entry.appendChild(main)
  return entry
}

// Annotation body + comment + replies as avatar-led entries joined by a thread line.
export function buildThread(ann: Annotation, header: HTMLElement, editor: Editor | null): HTMLElement {
  const thread = document.createElement('div')
  thread.className = 'ann-thread'

  const bodies: HTMLElement[] = []
  const body = document.createElement('div')
  body.className = 'ann-card-body'
  if (ann.kind === 'comment') {
    if (editor) body.appendChild(renderMarkdownContent(ann.comment ?? '', editor))
  } else {
    body.textContent = formatBody(ann)
  }
  bodies.push(body)
  if (ann.kind !== 'comment' && ann.comment && editor) {
    const commentEl = document.createElement('div')
    commentEl.className = 'ann-card-comment'
    commentEl.appendChild(renderMarkdownContent(ann.comment, editor))
    bodies.push(commentEl)
  }
  thread.appendChild(makeEntry(displayName(ann.author), header, bodies))

  if (editor) {
    for (const reply of ann.replies ?? []) {
      const replyHeader = document.createElement('div')
      replyHeader.className = 'ann-reply-header'
      const replyAuthor = document.createElement('strong')
      replyAuthor.className = 'ann-reply-author'
      replyAuthor.textContent = displayName(reply.author)
      const replyTime = document.createElement('span')
      replyTime.className = 'ann-reply-time'
      replyTime.textContent = formatTime(reply.created)
      replyHeader.appendChild(replyAuthor)
      replyHeader.appendChild(replyTime)
      const replyBody = document.createElement('div')
      replyBody.className = 'ann-reply-body'
      replyBody.appendChild(renderMarkdownContent(reply.body, editor))
      thread.appendChild(makeEntry(displayName(reply.author), replyHeader, [replyBody]))
    }
  }
  return thread
}

// Always-visible reply field: rounded input with a circular send button.
export function makeReplyBox(): { box: HTMLElement; textarea: HTMLTextAreaElement; send: HTMLButtonElement; refresh: () => void } {
  const box = document.createElement('div')
  box.className = 'ann-card-actions ann-reply-box'
  const textarea = document.createElement('textarea')
  textarea.className = 'ann-reply-textarea'
  textarea.placeholder = 'Reply…'
  textarea.rows = 1
  const send = document.createElement('button')
  send.className = 'ann-send-btn'
  send.title = 'Reply'
  send.innerHTML = '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M8 13V3M3.5 7.5 8 3l4.5 4.5"/></svg>'
  const refresh = () => send.classList.toggle('ready', textarea.value.trim().length > 0)
  textarea.addEventListener('input', refresh)
  const field = document.createElement('div')
  field.className = 'ann-reply-field'
  field.appendChild(textarea)
  field.appendChild(send)
  box.appendChild(makeAvatar(displayName('me')))
  box.appendChild(field)
  return { box, textarea, send, refresh }
}

function makeGutterCard(ann: Annotation, editor: Editor, gutterEl: HTMLElement): HTMLElement {
  const card = document.createElement('div')
  card.className = 'ann-card'
  card.dataset.source = ann.source
  card.dataset.id = ann.id

  const header = makeHeader(ann, {
    accept: () => {
      if (ann.kind === 'comment') {
        annotationKeyboardUndoStack.push({ snapshot: [...currentSidecar.annotations], pmDepth: undoDepth(editor.view.state) })
        resolveAnnotation(ann, 'dismissed', editor)
      } else {
        acceptAnnotation(ann.id)
      }
    },
    remove: () => {
      annotationKeyboardUndoStack.push({ snapshot: [...currentSidecar.annotations], pmDepth: undoDepth(editor.view.state) })
      resolveAnnotation(ann, ann.kind === 'comment' ? 'dismissed' : 'rejected', editor)
    },
    edit: (c, g) => startEditComment(c, ann, g, text => {
      setAnnotationComment(ann.id, text)
      editor.view.dispatch(editor.state.tr)
    }),
  }, gutterEl)
  card.appendChild(buildThread(ann, header, editor))

  const { box: actions, textarea, send, refresh } = makeReplyBox()
  textarea.value = replyDrafts.get(ann.id) ?? ''
  refresh()
  if (textarea.value) {
    // restore height for non-empty drafts after rebuild
    requestAnimationFrame(() => {
      textarea.style.height = 'auto'
      textarea.style.height = `${textarea.scrollHeight}px`
      repositionCards(gutterEl)
    })
  }
  textarea.addEventListener('input', () => {
    textarea.style.height = 'auto'
    textarea.style.height = `${textarea.scrollHeight}px`
    replyDrafts.set(ann.id, textarea.value)
    repositionCards(gutterEl)
  })

  const submitReply = () => {
    const body = textarea.value.trim()
    if (!body) return
    const reply: ThreadReply = {
      id: `reply-${Date.now()}`,
      author: 'me',
      source: 'local',
      body,
      created: new Date().toISOString(),
    }
    const updated: Sidecar = {
      ...currentSidecar,
      annotations: currentSidecar.annotations.map(a =>
        a.id === ann.id ? { ...a, replies: [...(a.replies ?? []), reply] } : a,
      ),
    }
    replyDrafts.delete(ann.id)
    currentSidecar = updated
    putFolio(updated)
    sidecarUpdateCb?.()
    editor.view.dispatch(editor.state.tr)
  }

  textarea.addEventListener('keydown', e => {
    if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
      e.preventDefault()
      submitReply()
    }
  })

  send.addEventListener('mousedown', e => {
    e.preventDefault()
    submitReply()
  })

  card.appendChild(actions)

  card.addEventListener('mousedown', e => {
    if ((e.target as HTMLElement).closest('.ann-card-actions')) return
    e.preventDefault()
    focusedAnnotationId = ann.id
    shouldFocusReply = true
    updateFocusedCard()
    textarea.focus()
  })

  return card
}

export function repositionCards(gutterEl: HTMLElement, floorHeight = 0): void {
  const items = Array.from(gutterEl.querySelectorAll<HTMLElement>('.ann-card, .cf-gutter-form'))
  items.sort((a, b) => parseFloat(a.dataset.anchorFrom ?? '0') - parseFloat(b.dataset.anchorFrom ?? '0'))

  const GAP = 6
  const BOTTOM_PAD = 48
  let minTop = 0
  for (const item of items) {
    if (item.hidden) continue
    const anchor = parseFloat(item.dataset.anchorTop ?? '0')
    const top = Math.max(anchor - 4, minTop)
    item.style.top = `${top}px`
    minTop = top + item.offsetHeight + GAP
  }

  const needed = Math.max(minTop > 0 ? minTop + BOTTOM_PAD : 0, floorHeight)
  const current = parseFloat(gutterEl.style.minHeight) || 0
  if (needed > current) gutterEl.style.minHeight = `${needed}px`
}

function buildGutterCards(pmView: EditorView, gutterEl: HTMLElement, editor: Editor): void {
  for (const el of gutterEl.querySelectorAll('.ann-card')) el.remove()

  const pending = currentSidecar.annotations.filter(a => !a.resolved)
  if (pending.length === 0) {
    gutterEl.style.minHeight = `${pmView.dom.scrollHeight}px`
    return
  }

  const wrapper = gutterEl.parentElement
  if (!wrapper) return

  const wrapperRect = wrapper.getBoundingClientRect()
  const pluginAnchors = annotationsKey.getState(pmView.state)?.anchors

  const entries: Array<{ ann: Annotation; top: number; from: number }> = []
  for (const ann of pending) {
    const anchor = pluginAnchors?.get(ann.id)
    if (!anchor) continue
    let top = 0
    try {
      const coords = pmView.coordsAtPos(anchor.from)
      top = coords.top - wrapperRect.top + wrapper.scrollTop
    } catch {
      // View not yet laid out — card appears at top and repositions on next update
    }
    entries.push({ ann, top, from: anchor.from })
  }

  entries.sort((a, b) => a.from - b.from)

  for (const { ann, top, from } of entries) {
    const card = makeGutterCard(ann, editor, gutterEl)
    card.dataset.anchorTop = String(top)
    card.dataset.anchorFrom = String(from)
    card.style.top = `${top}px`
    gutterEl.appendChild(card)
  }

  const anchoredIds = new Set(entries.map(e => e.ann.id))
  for (const ann of pending) {
    if (anchoredIds.has(ann.id)) continue
    const card = makeGutterCard(ann, editor, gutterEl)
    card.classList.add('ann-card-unanchored')
    card.dataset.anchorTop = '0'
    card.dataset.anchorFrom = '-1'
    card.style.top = '0px'
    const badge = document.createElement('span')
    badge.className = 'ann-card-lost-badge'
    badge.textContent = 'Not found in document'
    card.insertBefore(badge, card.firstChild)
    gutterEl.appendChild(card)
  }

  repositionCards(gutterEl, pmView.dom.scrollHeight)
  updateFocusedCard()

  if (shouldFocusReply && focusedAnnotationId) {
    shouldFocusReply = false
    gutterEl
      .querySelector<HTMLElement>(`[data-id="${focusedAnnotationId}"]`)
      ?.querySelector<HTMLTextAreaElement>('.ann-reply-textarea')
      ?.focus()
  }
}

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
                // The entire document was replaced (e.g. switching back from source
                // view). Any mapped positions are invalid — clear them immediately so
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

              if (meta?.type === 'resolve' && meta.id) {
                // One annotation was accepted/rejected: remove it from the map.
                // Positions of remaining annotations were already updated by the
                // doc-change transaction that ran just before this one.
                const anchors = new Map(value.anchors)
                anchors.delete(meta.id)
                return { ...value, anchors, decoSet: buildDecosFromAnchors(anchors, tr.doc, editor) }
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
            handleKeyDown(view, event) {
              if (event.key === 'z' && (event.ctrlKey || event.metaKey) && !event.shiftKey && !event.altKey) {
                const top = annotationKeyboardUndoStack[annotationKeyboardUndoStack.length - 1]
                if (top && top.pmDepth === undoDepth(view.state)) {
                  annotationKeyboardUndoStack.pop()
                  currentSidecar = { ...currentSidecar, annotations: top.snapshot }
                  putFolio(currentSidecar)
                  sidecarUpdateCb?.()
                  editor.view.dispatch(editor.state.tr.setMeta(annotationsKey, { type: 'sidecar-updated' }))
                  return true
                }
              }
              if (event.ctrlKey && !event.shiftKey && !event.altKey && !event.metaKey) {
                if (event.key === 'j') return navigateAnnotation(1, view)
                if (event.key === 'k') return navigateAnnotation(-1, view)
                if (event.key === 'Enter' && focusedAnnotationId) {
                  const ann = currentSidecar.annotations.find(a => a.id === focusedAnnotationId && !a.resolved)
                  if (ann) {
                    acceptAnnotation(ann.id)
                    return true
                  }
                }
                if (event.key === 'Backspace' && focusedAnnotationId) {
                  const ann = currentSidecar.annotations.find(a => a.id === focusedAnnotationId && !a.resolved)
                  if (ann) {
                    annotationKeyboardUndoStack.push({ snapshot: [...currentSidecar.annotations], pmDepth: undoDepth(view.state) })
                    resolveAnnotation(ann, ann.kind === 'comment' ? 'dismissed' : 'rejected', editor)
                    return true
                  }
                }
              }
              return false
            },
            handleClick(view, pos) {
              const pending = currentSidecar.annotations.filter(a => !a.resolved)
              const pluginAnchors = annotationsKey.getState(view.state)?.anchors
              let found: string | null = null
              for (const ann of pending) {
                const anchor = pluginAnchors?.get(ann.id)
                if (anchor && pos >= anchor.from && pos <= anchor.to) {
                  found = ann.id
                  break
                }
              }
              if (focusedAnnotationId !== found) {
                focusedAnnotationId = found
                updateFocusedCard()
              }
              return false
            },
          },

          view(pmView) {
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
              const charPos = buildCharPos(view.state.doc)
              const items = currentSidecar.annotations
                .filter(a => !a.resolved)
                .map(a => ({ id: a.id, context_before: a.context_before, target: a.target ?? undefined }))

              postAnchor(items)
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

            const gutterEl = document.createElement('div')
            gutterEl.id = 'annotation-gutter'
            currentGutterEl = gutterEl

            const scrollContainer = pmView.dom.parentElement?.parentElement
            if (scrollContainer) scrollContainer.appendChild(gutterEl)

            // ── Action overlay (accept / reject) ────────────────────────────
            const actionFloater = document.createElement('div')
            actionFloater.id = 'action-floater'
            actionFloater.hidden = true
            if (scrollContainer) scrollContainer.appendChild(actionFloater)

            const afAccept = document.createElement('button')
            afAccept.className = 'af-btn'
            afAccept.textContent = 'Accept'
            afAccept.addEventListener('mousedown', e => {
              e.preventDefault()
              if (focusedAnnotationId) acceptAnnotation(focusedAnnotationId)
            })

            const afDivider = document.createElement('span')
            afDivider.className = 'af-divider'

            const afReject = document.createElement('button')
            afReject.className = 'af-btn'
            afReject.textContent = 'Reject'
            afReject.addEventListener('mousedown', e => {
              e.preventDefault()
              const ann = currentSidecar.annotations.find(a => a.id === focusedAnnotationId)
              if (ann) {
                annotationKeyboardUndoStack.push({ snapshot: [...currentSidecar.annotations], pmDepth: undoDepth(editor.view.state) })
                resolveAnnotation(ann, 'rejected', editor)
              }
            })

            actionFloater.appendChild(afAccept)
            actionFloater.appendChild(afDivider)
            actionFloater.appendChild(afReject)

            focusChangeCallback = () => {
              const ann = focusedAnnotationId
                ? currentSidecar.annotations.find(a => a.id === focusedAnnotationId && a.kind !== 'comment')
                : null
              if (!ann || !scrollContainer) { actionFloater.hidden = true; return }
              const anchor = annotationsKey.getState(pmView.state)?.anchors.get(ann.id)
              if (!anchor) { actionFloater.hidden = true; return }
              try {
                const containerRect = scrollContainer.getBoundingClientRect()
                const coordsFrom = pmView.coordsAtPos(anchor.from)
                const coordsTo = pmView.coordsAtPos(anchor.to)
                const midX = (coordsFrom.left + coordsTo.right) / 2
                const top = coordsFrom.top - containerRect.top + scrollContainer.scrollTop
                const left = Math.max(80, Math.min(midX - containerRect.left, scrollContainer.clientWidth - 80))
                actionFloater.style.top = `${top}px`
                actionFloater.style.left = `${left}px`
                actionFloater.hidden = false
              } catch {
                actionFloater.hidden = true
              }
            }
            // ───────────────────────────────────────────────────────────────

            // ── Floating comment adder ──────────────────────────────────────
            const floater = document.createElement('div')
            floater.id = 'comment-floater'
            floater.hidden = true
            if (scrollContainer) scrollContainer.appendChild(floater)

            const cfBtn = document.createElement('button')
            cfBtn.className = 'af-btn'
            cfBtn.textContent = 'Comment'
            floater.appendChild(cfBtn)

            const cfGutterForm = document.createElement('div')
            cfGutterForm.className = 'cf-gutter-form'
            cfGutterForm.hidden = true
            gutterEl.appendChild(cfGutterForm)

            const cfTitle = document.createElement('div')
            cfTitle.className = 'cf-title'
            cfTitle.textContent = 'New comment'
            cfGutterForm.appendChild(cfTitle)

            const cfTextarea = document.createElement('textarea')
            cfTextarea.className = 'ann-reply-textarea'
            cfTextarea.placeholder = 'Add a comment…'
            cfTextarea.rows = 1
            cfTextarea.addEventListener('input', () => {
              cfTextarea.style.height = 'auto'
              cfTextarea.style.height = `${cfTextarea.scrollHeight}px`
              repositionCards(gutterEl)
            })

            const cfActions = document.createElement('div')
            cfActions.className = 'ann-card-action-row'
            const cfSubmit = document.createElement('button')
            cfSubmit.className = 'ann-card-btn ann-card-reply'
            cfSubmit.textContent = 'Add'
            const cfCancel = document.createElement('button')
            cfCancel.className = 'cf-cancel'
            cfCancel.textContent = 'Cancel'
            cfActions.appendChild(cfSubmit)
            cfActions.appendChild(cfCancel)
            cfGutterForm.appendChild(cfTextarea)
            cfGutterForm.appendChild(cfActions)

            let savedSelection: { from: number; to: number } | null = null

            function hideFloater(): void {
              floater.hidden = true
              cfGutterForm.hidden = true
              cfTextarea.value = ''
              cfTextarea.style.height = ''
              savedSelection = null
              pendingCommentRange = null
              const { from } = pmView.state.selection
              pmView.dispatch(
                pmView.state.tr
                  .setSelection(TextSelection.create(pmView.state.doc, from))
                  .setMeta(annotationsKey, { type: 'refresh' }),
              )
              repositionCards(gutterEl)
            }

            cfBtn.addEventListener('mousedown', e => {
              e.preventDefault()
              const anchorTop = parseFloat(floater.style.top ?? '0')
              cfGutterForm.dataset.anchorTop = String(anchorTop)
              cfGutterForm.dataset.anchorFrom = String(savedSelection?.from ?? 0)
              cfGutterForm.style.top = `${anchorTop}px`
              cfGutterForm.hidden = false
              window.dispatchEvent(new Event('folio:open-gutter'))
              floater.hidden = true
              pendingCommentRange = savedSelection
              pmView.dispatch(pmView.state.tr.setMeta(annotationsKey, { type: 'refresh' }))
              repositionCards(gutterEl)
              cfTextarea.focus()
            })

            cfCancel.addEventListener('mousedown', e => {
              e.preventDefault()
              hideFloater()
            })

            cfSubmit.addEventListener('mousedown', e => {
              e.preventDefault()
              const comment = cfTextarea.value.trim()
              if (!comment || !savedSelection) { hideFloater(); return }
              const { from, to } = savedSelection
              const doc = pmView.state.doc
              const target = doc.textBetween(from, to, '')
              const contextBefore = doc.textBetween(0, from, '').slice(-30)
              addCommentAnnotation(contextBefore, target, comment, editor)
              hideFloater()
            })
            // ───────────────────────────────────────────────────────────────

            const onScroll = () => buildGutterCards(pmView, gutterEl, editor)
            scrollContainer?.addEventListener('scroll', onScroll)

            rebuildFn = () => buildGutterCards(pmView, gutterEl, editor)
            requestAnimationFrame(() => rebuildFn && requestAnimationFrame(rebuildFn))

            // Trigger the initial fetch — update() is not called on first mount.
            tryFetchAnchors(pmView)

            return {
              update(view) {
                tryFetchAnchors(view)

                buildGutterCards(view, gutterEl, editor)

                const { selection } = view.state
                if (!cfGutterForm.hidden) return // keep position stable while form is active
                if (selection.empty) { floater.hidden = true; return }

                try {
                  const containerRect = scrollContainer!.getBoundingClientRect()
                  const coordsFrom = view.coordsAtPos(selection.from)
                  const coordsTo = view.coordsAtPos(selection.to)
                  const midX = (coordsFrom.left + coordsTo.right) / 2
                  const top = coordsFrom.top - containerRect.top + scrollContainer!.scrollTop
                  const left = Math.max(80, Math.min(midX - containerRect.left, scrollContainer!.clientWidth - 80))
                  floater.style.top = `${top}px`
                  floater.style.left = `${left}px`
                  floater.hidden = false
                  savedSelection = { from: selection.from, to: selection.to }
                } catch {
                  floater.hidden = true
                }
              },
              destroy() {
                scrollContainer?.removeEventListener('scroll', onScroll)
                gutterEl.remove()
                floater.remove()
                actionFloater.remove()
                focusChangeCallback = null
                currentGutterEl = null
                rebuildFn = null
                pendingCommentRange = null
              },
            }
          },
        }),
      ]
    },
  })
}
