import { Extension } from '@tiptap/core'
import type { Editor } from '@tiptap/core'
import { Plugin, PluginKey } from '@tiptap/pm/state'
import { Decoration, DecorationSet } from '@tiptap/pm/view'
import type { Node as PMNode } from '@tiptap/pm/model'
import type { EditorView } from '@tiptap/pm/view'
import type { Annotation, Sidecar } from './api'
import { putFolio } from './api'

// ─── Sidecar state ───────────────────────────────────────────────────────────

let currentSidecar: Sidecar = { version: 1, annotations: [] }
let sidecarUpdateCb: (() => void) | null = null

// ─── Focus state ─────────────────────────────────────────────────────────────

let focusedAnnotationId: string | null = null
let currentGutterEl: HTMLElement | null = null

function updateFocusedCard(): void {
  if (!currentGutterEl) return
  currentGutterEl.querySelectorAll<HTMLElement>('.ann-card').forEach(card => {
    card.classList.toggle('ann-card-focused', card.dataset.id === focusedAnnotationId)
  })
}

export function updateSidecar(sidecar: Sidecar): void {
  currentSidecar = sidecar
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

  const search = (contextBefore + (target ?? '')).toLowerCase()
  const idx = flatText.toLowerCase().indexOf(search)
  if (idx === -1) return null

  const fromIdx = idx + contextBefore.length
  const toIdx = fromIdx + (target?.length ?? 0)

  if (fromIdx > charPos.length) return null

  const from = fromIdx < charPos.length ? charPos[fromIdx] : charPos[charPos.length - 1] + 1
  const to =
    toIdx > fromIdx
      ? toIdx < charPos.length
        ? charPos[toIdx]
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

function applyAccept(ann: Annotation, editor: Editor): void {
  const anchor = findAnchor(editor.state.doc, ann.context_before, ann.target)
  if (anchor) {
    const { from, to } = anchor
    if (ann.kind === 'replace') {
      if (ann.replacement) {
        editor.commands.insertContentAt({ from, to }, ann.replacement)
      } else {
        editor.commands.deleteRange({ from, to })
      }
    } else if (ann.kind === 'delete') {
      editor.commands.deleteRange({ from, to })
    } else if (ann.kind === 'insert') {
      editor.commands.insertContentAt(from, ann.replacement ?? '')
    }
  }
  resolveAnnotation(ann, 'accepted', editor)
}

// ─── Inline decorations ───────────────────────────────────────────────────────

function buildDecorations(doc: PMNode): DecorationSet {
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
                const el = document.createElement('span')
                el.className = 'ann-insert-preview'
                el.textContent = ann.replacement!
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
        decos.push(
          Decoration.widget(
            from,
            () => {
              const el = document.createElement('span')
              el.className = 'ann-insert-preview'
              el.textContent = ann.replacement ?? ''
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

  return DecorationSet.create(doc, decos)
}

// ─── Gutter cards ─────────────────────────────────────────────────────────────

function formatSummary(ann: Annotation): string {
  const t = (s: string, max = 24) => (s.length > max ? s.slice(0, max) + '…' : s)
  switch (ann.kind) {
    case 'replace':
      return `◇ "${t(ann.target ?? '')}" → "${t(ann.replacement ?? '')}"`
    case 'delete':
      return `✕  "${t(ann.target ?? '')}"`
    case 'insert':
      return `+  "${t(ann.replacement ?? '')}"`
    case 'highlight':
      return `◌  "${t(ann.target ?? '')}"`
    case 'comment':
      return `💬 ${t(ann.comment ?? '', 32)}`
  }
}

function formatTime(iso: string): string {
  return new Date(iso).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
}

function makeGutterCard(ann: Annotation, editor: Editor): HTMLElement {
  const card = document.createElement('div')
  card.className = ann.kind === 'comment' ? 'ann-card ann-card--comment' : 'ann-card'
  card.dataset.source = ann.source
  card.dataset.id = ann.id

  const info = document.createElement('div')
  info.className = 'ann-card-info'

  const summary = document.createElement('div')
  summary.className = 'ann-card-summary'
  summary.textContent = formatSummary(ann)

  const meta = document.createElement('div')
  meta.className = 'ann-card-meta'
  meta.textContent = `${ann.author} · ${formatTime(ann.created)}`

  info.appendChild(summary)
  info.appendChild(meta)

  if (ann.kind === 'comment' && ann.comment) {
    const body = document.createElement('div')
    body.className = 'ann-card-comment-body'
    body.textContent = ann.comment
    card.appendChild(info)
    card.appendChild(body)

    card.addEventListener('mousedown', e => {
      if ((e.target as HTMLElement).closest('.ann-card-actions')) return
      e.preventDefault()
      card.classList.toggle('ann-card-expanded')
      if (currentGutterEl) repositionCards(currentGutterEl)
    })
  } else {
    card.appendChild(info)
  }

  const actions = document.createElement('div')
  actions.className = 'ann-card-actions'

  if (ann.kind === 'comment') {
    const dismiss = document.createElement('button')
    dismiss.className = 'ann-card-btn ann-card-dismiss'
    dismiss.textContent = 'Dismiss'
    dismiss.addEventListener('mousedown', e => {
      e.preventDefault()
      resolveAnnotation(ann, 'dismissed', editor)
    })
    actions.appendChild(dismiss)
  } else {
    const accept = document.createElement('button')
    accept.className = 'ann-card-btn ann-card-accept'
    accept.textContent = 'Accept'
    accept.addEventListener('mousedown', e => {
      e.preventDefault()
      applyAccept(ann, editor)
    })

    const reject = document.createElement('button')
    reject.className = 'ann-card-btn ann-card-reject'
    reject.textContent = 'Reject'
    reject.addEventListener('mousedown', e => {
      e.preventDefault()
      resolveAnnotation(ann, 'rejected', editor)
    })

    actions.appendChild(accept)
    actions.appendChild(reject)
  }
  card.appendChild(actions)
  return card
}

function repositionCards(gutterEl: HTMLElement): void {
  const cards = Array.from(gutterEl.querySelectorAll<HTMLElement>('.ann-card'))
  cards.sort((a, b) => parseFloat(a.dataset.anchorTop ?? '0') - parseFloat(b.dataset.anchorTop ?? '0'))

  const GAP = 6
  let minTop = 0
  for (const card of cards) {
    const anchor = parseFloat(card.dataset.anchorTop ?? '0')
    const top = Math.max(anchor - 4, minTop)
    card.style.top = `${top}px`
    minTop = top + card.offsetHeight + GAP
  }
}

function buildGutterCards(pmView: EditorView, gutterEl: HTMLElement, editor: Editor): void {
  gutterEl.innerHTML = ''

  const pending = currentSidecar.annotations.filter(a => !a.resolved)
  if (pending.length === 0) return

  const wrapper = gutterEl.parentElement
  if (!wrapper) return

  gutterEl.style.minHeight = `${pmView.dom.scrollHeight}px`

  const wrapperRect = wrapper.getBoundingClientRect()

  const entries: Array<{ ann: Annotation; top: number }> = []
  for (const ann of pending) {
    const anchor = findAnchor(pmView.state.doc, ann.context_before, ann.target)
    const pos = anchor ? anchor.from : null
    if (pos === null) continue
    try {
      const coords = pmView.coordsAtPos(pos)
      const top = coords.top - wrapperRect.top + wrapper.scrollTop
      entries.push({ ann, top })
    } catch {
      // Position currently off-screen — skip
    }
  }

  entries.sort((a, b) => a.top - b.top)

  for (const { ann, top } of entries) {
    const card = makeGutterCard(ann, editor)
    card.dataset.anchorTop = String(top)
    card.style.top = `${top}px`
    gutterEl.appendChild(card)
  }

  repositionCards(gutterEl)
  updateFocusedCard()
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
              return buildDecorations(state.doc)
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

            // ── Floating comment adder ──────────────────────────────────────
            const floater = document.createElement('div')
            floater.id = 'comment-floater'
            floater.hidden = true
            if (scrollContainer) scrollContainer.appendChild(floater)

            const cfBtn = document.createElement('button')
            cfBtn.className = 'cf-btn'
            cfBtn.textContent = '💬 Comment'

            const cfForm = document.createElement('div')
            cfForm.className = 'cf-form'
            cfForm.hidden = true

            const cfTextarea = document.createElement('textarea')
            cfTextarea.className = 'cf-textarea'
            cfTextarea.placeholder = 'Add a comment…'
            cfTextarea.rows = 3

            const cfActions = document.createElement('div')
            cfActions.className = 'cf-actions'
            const cfSubmit = document.createElement('button')
            cfSubmit.className = 'cf-submit'
            cfSubmit.textContent = 'Add'
            const cfCancel = document.createElement('button')
            cfCancel.className = 'cf-cancel'
            cfCancel.textContent = 'Cancel'
            cfActions.appendChild(cfSubmit)
            cfActions.appendChild(cfCancel)
            cfForm.appendChild(cfTextarea)
            cfForm.appendChild(cfActions)
            floater.appendChild(cfBtn)
            floater.appendChild(cfForm)

            let savedSelection: { from: number; to: number } | null = null

            function hideFloater(): void {
              floater.hidden = true
              cfBtn.hidden = false
              cfForm.hidden = true
              cfTextarea.value = ''
              savedSelection = null
            }

            cfBtn.addEventListener('mousedown', e => {
              e.preventDefault()
              cfBtn.hidden = true
              cfForm.hidden = false
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

            buildGutterCards(pmView, gutterEl, editor)

            return {
              update(view) {
                buildGutterCards(view, gutterEl, editor)

                const { selection } = view.state
                if (!cfForm.hidden) return // keep floater open while form is active
                if (selection.empty) { floater.hidden = true; return }

                try {
                  const containerRect = scrollContainer!.getBoundingClientRect()
                  const coords = view.coordsAtPos(selection.to)
                  const top = coords.bottom - containerRect.top + scrollContainer!.scrollTop + 6
                  const left = Math.min(
                    coords.left - containerRect.left,
                    scrollContainer!.clientWidth - 260,
                  )
                  floater.style.top = `${top}px`
                  floater.style.left = `${left}px`
                  floater.hidden = false
                  cfBtn.hidden = false
                  cfForm.hidden = true
                  savedSelection = { from: selection.from, to: selection.to }
                } catch {
                  floater.hidden = true
                }
              },
              destroy() {
                scrollContainer?.removeEventListener('scroll', onScroll)
                gutterEl.remove()
                floater.remove()
                currentGutterEl = null
              },
            }
          },
        }),
      ]
    },
  })
}
