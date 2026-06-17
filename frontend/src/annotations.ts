import { Extension } from '@tiptap/core'
import type { Editor, JSONContent } from '@tiptap/core'
import { Plugin, PluginKey, TextSelection } from '@tiptap/pm/state'
import { undoDepth, redoDepth } from '@tiptap/pm/history'
import { Decoration, DecorationSet } from '@tiptap/pm/view'
import { DOMSerializer, Node as PMNode } from '@tiptap/pm/model'
import type { EditorView } from '@tiptap/pm/view'
import type { Annotation, Sidecar, ThreadReply } from './api'
import { putFolio } from './api'

// ─── Sidecar state ───────────────────────────────────────────────────────────

let currentSidecar: Sidecar = { version: 1, annotations: [] }
let sidecarUpdateCb: (() => void) | null = null

// ─── Annotation undo/redo stacks ─────────────────────────────────────────────
// Each entry mirrors one ProseMirror undo history item.
// null = no annotation change at that history depth; Annotation[] = snapshot to restore.

let annotationUndoStack: (Annotation[] | null)[] = []
let annotationRedoStack: (Annotation[] | null)[] = []
let pendingAnnotationSnapshot: Annotation[] | null = null
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

function updateFocusedCard(): void {
  if (!currentGutterEl) return
  currentGutterEl.querySelectorAll<HTMLElement>('.ann-card').forEach(card => {
    card.classList.toggle('ann-card-focused', card.dataset.id === focusedAnnotationId)
  })
  repositionCards(currentGutterEl)
  focusChangeCallback?.()
}

export function updateSidecar(sidecar: Sidecar): void {
  const isEcho = JSON.stringify(sidecar) === JSON.stringify(currentSidecar)
  currentSidecar = sidecar
  if (isEcho) return
  annotationUndoStack = []
  annotationRedoStack = []
  pendingAnnotationSnapshot = null
  annotationKeyboardUndoStack = []
  replyDrafts.clear()
}

export function getSidecar(): Sidecar {
  return currentSidecar
}

export function onSidecarUpdate(cb: () => void): void {
  sidecarUpdateCb = cb
}

// ─── Anchoring ───────────────────────────────────────────────────────────────

export function findAnchor(
  doc: PMNode,
  contextBefore: string,
  target: string | null | undefined,
): { from: number; to: number } | null {
  let flatText = ''
  const charPos: number[] = []

  doc.descendants((node, pos) => {
    if (node.isText) {
      for (let i = 0; i < node.text!.length; i++) {
        charPos.push(pos + i)
      }
      flatText += node.text
    }
  })

  // Strip newlines and decode HTML entities from search terms. The flat text has
  // no block separators and uses decoded characters (ProseMirror stores text
  // decoded), so agent-written values with &amp; etc. must be normalised to match.
  const decodeEntities = (s: string) =>
    s.replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&apos;/g, "'")
  const normCtx = decodeEntities(contextBefore.replace(/\n/g, ''))
  const normTarget = decodeEntities((target ?? '').replace(/\n/g, ''))
  const flat = flatText.toLowerCase()
  const search = (normCtx + normTarget).toLowerCase()
  let idx = flat.indexOf(search)
  let spaceOffset = 0
  if (idx === -1 && target) {
    const searchSpaced = (normCtx + ' ' + normTarget).toLowerCase()
    idx = flat.indexOf(searchSpaced)
    spaceOffset = 1
  }
  if (idx === -1) return null

  const fromIdx = idx + normCtx.length + spaceOffset
  const toIdx = fromIdx + normTarget.length

  if (fromIdx > charPos.length) return null

  // For annotations with a target: from = position of first target char.
  // For insert/comment (no target): position just after the last char of context_before,
  // which keeps the anchor within the same block at block boundaries instead of
  // jumping to charPos[fromIdx] (the first char of the next block).
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

export function resolveAnnotation(ann: Annotation, as: string, editor: Editor): void {
  const updated: Sidecar = {
    ...currentSidecar,
    annotations: currentSidecar.annotations.map(a =>
      a.id === ann.id
        ? { ...a, resolved: true, resolved_as: as, resolved_at: new Date().toISOString() }
        : a,
    ),
  }
  currentSidecar = updated
  putFolio(updated)
  sidecarUpdateCb?.()
  editor.view.dispatch(editor.state.tr)
}

function addCommentAnnotation(contextBefore: string, target: string, comment: string, editor: Editor): void {
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
  editor.view.dispatch(editor.state.tr)
}

function parseReplacementContent(markdown: string, editor: Editor): JSONContent | JSONContent[] {
  try {
    const mgr = editor.storage.markdown as { manager: { parse: (s: string) => JSONContent } }
    const json = mgr.manager.parse(markdown)
    const blocks = (json.content ?? []) as JSONContent[]
    // Single paragraph: lift inline nodes out so the replacement doesn't wrap in
    // a new block, and so explicit marks override any inherited surrounding marks.
    if (blocks.length === 1 && blocks[0].type === 'paragraph') {
      const inlineNodes = (blocks[0].content ?? []) as JSONContent[]
      if (inlineNodes.length === 0) return { type: 'text', text: '' }
      return inlineNodes.length === 1 ? inlineNodes[0] : inlineNodes
    }
    return blocks.length === 1 ? blocks[0] : blocks
  } catch {
    return { type: 'text', text: markdown }
  }
}

function applyAccept(ann: Annotation, editor: Editor): void {
  const anchor = findAnchor(editor.state.doc, ann.context_before, ann.target)
  if (anchor) {
    pendingAnnotationSnapshot = [...currentSidecar.annotations]
    const { from, to } = anchor
    if (ann.kind === 'replace') {
      if (ann.replacement) {
        editor.commands.insertContentAt({ from, to }, parseReplacementContent(ann.replacement, editor))
      } else {
        editor.commands.deleteRange({ from, to })
      }
    } else if (ann.kind === 'delete') {
      editor.commands.deleteRange({ from, to })
    } else if (ann.kind === 'insert') {
      if (ann.replacement) {
        const insIsBlock = ann.replacement.includes('\n')
        const insertPos = insIsBlock ? resolveAfterBlock(editor.state.doc, from) : from
        editor.commands.insertContentAt(insertPos, parseReplacementContent(ann.replacement, editor))
      }
    }
  }
  resolveAnnotation(ann, 'accepted', editor)
}

// ─── Annotation keyboard navigation ─────────────────────────────────────────

function navigateAnnotation(direction: 1 | -1, view: EditorView): boolean {
  const pending = currentSidecar.annotations.filter(a => !a.resolved)
  if (pending.length === 0) return false

  const sorted: Array<{ ann: Annotation; from: number }> = []
  for (const ann of pending) {
    const anchor = findAnchor(view.state.doc, ann.context_before, ann.target)
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

function resolveAfterBlock(doc: PMNode, pos: number): number {
  const clamped = Math.min(Math.max(pos, 0), doc.content.size)
  const $pos = doc.resolve(clamped)
  return $pos.depth > 0 ? $pos.after(1) : clamped
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


function buildDecorations(doc: PMNode, editor: Editor): DecorationSet {
  const pending = currentSidecar.annotations.filter(a => !a.resolved)
  const decos: Decoration[] = []

  for (const ann of pending) {
    const anchor = findAnchor(doc, ann.context_before, ann.target)
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

function formatBody(ann: Annotation): string {
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

function formatTime(iso: string): string {
  return new Date(iso).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
}

function makeHeader(ann: Annotation): HTMLElement {
  const header = document.createElement('div')
  header.className = 'ann-card-header'
  const author = document.createElement('strong')
  author.className = 'ann-card-author'
  author.textContent = ann.author
  const time = document.createElement('span')
  time.className = 'ann-card-time'
  time.textContent = formatTime(ann.created)
  header.appendChild(author)
  header.appendChild(time)
  return header
}

function makeGutterCard(ann: Annotation, editor: Editor, gutterEl: HTMLElement): HTMLElement {
  const card = document.createElement('div')
  card.className = 'ann-card'
  card.dataset.source = ann.source
  card.dataset.id = ann.id

  card.appendChild(makeHeader(ann))

  if (ann.kind === 'comment') {
    const body = document.createElement('div')
    body.className = 'ann-card-body'
    body.appendChild(renderMarkdownContent(ann.comment ?? '', editor))
    card.appendChild(body)
  } else {
    const body = document.createElement('div')
    body.className = 'ann-card-body'
    body.textContent = formatBody(ann)
    card.appendChild(body)

    if (ann.comment) {
      const commentEl = document.createElement('div')
      commentEl.className = 'ann-card-comment'
      commentEl.appendChild(renderMarkdownContent(ann.comment, editor))
      card.appendChild(commentEl)
    }
  }

  if ((ann.replies ?? []).length > 0) {
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
      replyBody.appendChild(renderMarkdownContent(reply.body, editor))
      replyEl.appendChild(replyHeader)
      replyEl.appendChild(replyBody)
      repliesSection.appendChild(replyEl)
    }
    card.appendChild(repliesSection)
  }

  // ── Actions: textarea + buttons (shown when focused) ──
  const actions = document.createElement('div')
  actions.className = 'ann-card-actions'

  const textarea = document.createElement('textarea')
  textarea.className = 'ann-reply-textarea'
  textarea.placeholder = 'Reply…'
  textarea.rows = 1
  textarea.value = replyDrafts.get(ann.id) ?? ''
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
  actions.appendChild(textarea)

  const btnRow = document.createElement('div')
  btnRow.className = 'ann-card-action-row'

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

  if (ann.kind === 'comment') {
    const dismiss = document.createElement('button')
    dismiss.className = 'ann-card-btn ann-card-dismiss'
    dismiss.textContent = 'Resolve'
    dismiss.addEventListener('mousedown', e => {
      e.preventDefault()
      annotationKeyboardUndoStack.push({ snapshot: [...currentSidecar.annotations], pmDepth: undoDepth(editor.view.state) })
      resolveAnnotation(ann, 'dismissed', editor)
    })
    btnRow.appendChild(dismiss)
  }

  const replyBtn = document.createElement('button')
  replyBtn.className = 'ann-card-btn ann-card-reply'
  replyBtn.textContent = 'Reply'
  replyBtn.addEventListener('mousedown', e => {
    e.preventDefault()
    submitReply()
  })
  btnRow.appendChild(replyBtn)

  actions.appendChild(btnRow)

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

function repositionCards(gutterEl: HTMLElement, floorHeight = 0): void {
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

  const entries: Array<{ ann: Annotation; top: number; from: number }> = []
  for (const ann of pending) {
    const anchor = findAnchor(pmView.state.doc, ann.context_before, ann.target)
    if (!anchor) continue
    try {
      const coords = pmView.coordsAtPos(anchor.from)
      const top = coords.top - wrapperRect.top + wrapper.scrollTop
      entries.push({ ann, top, from: anchor.from })
    } catch {
      // Position currently off-screen — skip
    }
  }

  entries.sort((a, b) => a.from - b.from)

  for (const { ann, top, from } of entries) {
    const card = makeGutterCard(ann, editor, gutterEl)
    card.dataset.anchorTop = String(top)
    card.dataset.anchorFrom = String(from)
    card.style.top = `${top}px`
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

const annotationsKey = new PluginKey<DecorationSet>('folioAnnotations')

export function createAnnotationsExtension(): Extension {
  return Extension.create({
    name: 'folioAnnotations',

    addProseMirrorPlugins() {
      const editor = this.editor

      return [
        new Plugin({
          key: annotationsKey,

          props: {
            decorations(state) {
              return buildDecorations(state.doc, editor)
            },
            handleKeyDown(view, event) {
              if (event.key === 'z' && (event.ctrlKey || event.metaKey) && !event.shiftKey && !event.altKey) {
                const top = annotationKeyboardUndoStack[annotationKeyboardUndoStack.length - 1]
                if (top && top.pmDepth === undoDepth(view.state)) {
                  annotationKeyboardUndoStack.pop()
                  currentSidecar = { ...currentSidecar, annotations: top.snapshot }
                  putFolio(currentSidecar)
                  sidecarUpdateCb?.()
                  editor.view.dispatch(editor.state.tr)
                  return true
                }
              }
              if (event.ctrlKey && !event.shiftKey && !event.altKey && !event.metaKey) {
                if (event.key === 'j') return navigateAnnotation(1, view)
                if (event.key === 'k') return navigateAnnotation(-1, view)
                if (event.key === 'Enter' && focusedAnnotationId) {
                  const ann = currentSidecar.annotations.find(a => a.id === focusedAnnotationId && !a.resolved)
                  if (ann) {
                    if (ann.kind === 'highlight' || ann.kind === 'comment') {
                      annotationKeyboardUndoStack.push({ snapshot: [...currentSidecar.annotations], pmDepth: undoDepth(view.state) })
                    }
                    applyAccept(ann, editor)
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
              let found: string | null = null
              for (const ann of pending) {
                const anchor = findAnchor(view.state.doc, ann.context_before, ann.target)
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
              const ann = currentSidecar.annotations.find(a => a.id === focusedAnnotationId)
              if (ann) applyAccept(ann, editor)
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
              const anchor = findAnchor(pmView.state.doc, ann.context_before, ann.target)
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
              pmView.dispatch(pmView.state.tr.setSelection(TextSelection.create(pmView.state.doc, from)))
              repositionCards(gutterEl)
            }

            cfBtn.addEventListener('mousedown', e => {
              e.preventDefault()
              const anchorTop = parseFloat(floater.style.top ?? '0')
              cfGutterForm.dataset.anchorTop = String(anchorTop)
              cfGutterForm.dataset.anchorFrom = String(savedSelection?.from ?? 0)
              cfGutterForm.style.top = `${anchorTop}px`
              cfGutterForm.hidden = false
              floater.hidden = true
              pendingCommentRange = savedSelection
              pmView.dispatch(pmView.state.tr)
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
            requestAnimationFrame(rebuildFn)

            return {
              update(view, prevState) {
                if (prevState) {
                  const undoBefore = undoDepth(prevState)
                  const undoAfter = undoDepth(view.state)
                  const redoBefore = redoDepth(prevState)
                  const redoAfter = redoDepth(view.state)

                  if (undoAfter < undoBefore) {
                    // Undo — pop annotation snapshot and push to redo
                    const snapshot = annotationUndoStack.pop()
                    if (snapshot !== undefined) {
                      if (snapshot !== null) {
                        annotationRedoStack.push([...currentSidecar.annotations])
                        currentSidecar = { ...currentSidecar, annotations: snapshot }
                        putFolio(currentSidecar)
                        sidecarUpdateCb?.()
                        requestAnimationFrame(() => view.dispatch(view.state.tr))
                      } else {
                        annotationRedoStack.push(null)
                      }
                    }
                  } else if (undoAfter > undoBefore) {
                    if (redoAfter === redoBefore - 1) {
                      // Redo — pop annotation snapshot and push back to undo
                      const snapshot = annotationRedoStack.pop()
                      if (snapshot !== undefined) {
                        if (snapshot !== null) {
                          annotationUndoStack.push([...currentSidecar.annotations])
                          currentSidecar = { ...currentSidecar, annotations: snapshot }
                          putFolio(currentSidecar)
                          sidecarUpdateCb?.()
                          requestAnimationFrame(() => view.dispatch(view.state.tr))
                        } else {
                          annotationUndoStack.push(null)
                        }
                      }
                    } else {
                      // New edit — commit pending snapshot (or null) and clear redo
                      annotationUndoStack.push(pendingAnnotationSnapshot)
                      pendingAnnotationSnapshot = null
                      annotationRedoStack = []
                    }
                  }
                }

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
