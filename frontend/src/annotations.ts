import {
  Decoration,
  DecorationSet,
  EditorView,
  ViewPlugin,
  ViewUpdate,
  WidgetType,
} from '@codemirror/view'
import { RangeSetBuilder } from '@codemirror/state'
import { Annotation, Sidecar, putFolio } from './api'

// ─── Anchoring ───────────────────────────────────────────────────────────────

function anchorAnnotation(doc: string, ann: Annotation): number | null {
  const docLower = doc.toLowerCase()
  const ctxLower = ann.context_before.toLowerCase()

  if (ann.target) {
    const search = ctxLower + ann.target.toLowerCase()
    const pos = docLower.indexOf(search)
    if (pos === -1) return null
    return pos + ann.context_before.length
  } else {
    const pos = docLower.indexOf(ctxLower)
    if (pos === -1) return null
    return pos + ann.context_before.length
  }
}

// ─── Widgets ─────────────────────────────────────────────────────────────────

class AcceptRejectWidget extends WidgetType {
  constructor(
    private ann: Annotation,
    private sidecar: Sidecar,
    private view: EditorView,
    private targetStart: number,
    private targetEnd: number,
  ) { super() }

  toDOM(): HTMLElement {
    const wrap = document.createElement('span')
    wrap.className = 'ann-widget'

    if (this.ann.replacement !== null && this.ann.replacement !== undefined) {
      const preview = document.createElement('span')
      preview.className = 'ann-replacement-preview'
      preview.textContent = this.ann.replacement.slice(0, 40) + (this.ann.replacement.length > 40 ? '…' : '')
      wrap.appendChild(preview)
    }

    const accept = document.createElement('button')
    accept.className = 'ann-btn ann-btn-accept'
    accept.textContent = '✓'
    accept.title = 'Accept'
    accept.addEventListener('mousedown', e => {
      e.preventDefault()
      this.handleAccept()
    })

    const reject = document.createElement('button')
    reject.className = 'ann-btn ann-btn-reject'
    reject.textContent = '✗'
    reject.title = 'Reject'
    reject.addEventListener('mousedown', e => {
      e.preventDefault()
      this.handleReject()
    })

    wrap.appendChild(accept)
    wrap.appendChild(reject)
    return wrap
  }

  private handleAccept(): void {
    const { ann, view, targetStart, targetEnd } = this

    let insertion = ''
    if (ann.kind === 'replace' || ann.kind === 'insert') {
      insertion = ann.replacement ?? ''
    }

    if (ann.kind !== 'comment' && ann.kind !== 'highlight') {
      view.dispatch({ changes: { from: targetStart, to: targetEnd, insert: insertion } })
    }

    this.resolveAnnotation('accepted')
  }

  private handleReject(): void {
    this.resolveAnnotation('rejected')
  }

  private resolveAnnotation(as: string): void {
    const updated: Sidecar = {
      ...this.sidecar,
      annotations: this.sidecar.annotations.map(a =>
        a.id === this.ann.id
          ? { ...a, resolved: true, resolved_as: as, resolved_at: new Date().toISOString() }
          : a
      ),
    }
    putFolio(updated)
  }

  eq(other: WidgetType): boolean {
    return other instanceof AcceptRejectWidget && other.ann.id === this.ann.id
  }
}

class InsertMarkerWidget extends WidgetType {
  toDOM(): HTMLElement {
    const el = document.createElement('span')
    el.className = 'ann-insert-marker'
    return el
  }
  eq(): boolean { return true }
}

class CommentPinWidget extends WidgetType {
  constructor(private ann: Annotation) { super() }

  toDOM(): HTMLElement {
    const el = document.createElement('span')
    el.className = 'ann-comment-pin'
    el.textContent = '💬'
    el.title = this.ann.comment ?? ''
    return el
  }

  eq(other: WidgetType): boolean {
    return other instanceof CommentPinWidget && other.ann.id === this.ann.id
  }
}

// ─── ViewPlugin ──────────────────────────────────────────────────────────────

let currentSidecar: Sidecar = { version: 1, annotations: [] }

export function updateSidecar(sidecar: Sidecar): void {
  currentSidecar = sidecar
}

export function getSidecar(): Sidecar {
  return currentSidecar
}

function sourceClass(source: string): string {
  if (source === 'github' || source === 'gitlab') return 'ann-github'
  return `ann-${source}`
}

function buildDecorations(view: EditorView): DecorationSet {
  const doc = view.state.doc.toString()
  const builder = new RangeSetBuilder<Decoration>()

  const pending = currentSidecar.annotations.filter(a => !a.resolved)

  // Collect and sort by anchor position
  const anchored: Array<{ ann: Annotation; pos: number }> = []
  for (const ann of pending) {
    const pos = anchorAnnotation(doc, ann)
    if (pos !== null) anchored.push({ ann, pos })
  }
  anchored.sort((a, b) => a.pos - b.pos)

  for (const { ann, pos } of anchored) {
    const cls = sourceClass(ann.source)
    const targetLen = ann.target?.length ?? 0
    const targetEnd = pos + targetLen

    switch (ann.kind) {
      case 'replace':
      case 'delete': {
        // Mark the target with colour + strikethrough
        builder.add(pos, targetEnd, Decoration.mark({ class: `${cls} ann-strikethrough` }))
        // Accept/reject widget after the target
        builder.add(
          targetEnd,
          targetEnd,
          Decoration.widget({
            widget: new AcceptRejectWidget(ann, currentSidecar, view, pos, targetEnd),
            side: 1,
          }),
        )
        break
      }
      case 'insert': {
        builder.add(pos, pos, Decoration.widget({ widget: new InsertMarkerWidget(), side: 0 }))
        builder.add(
          pos,
          pos,
          Decoration.widget({
            widget: new AcceptRejectWidget(ann, currentSidecar, view, pos, pos),
            side: 1,
          }),
        )
        break
      }
      case 'comment': {
        builder.add(pos, pos, Decoration.widget({ widget: new CommentPinWidget(ann), side: 1 }))
        break
      }
      case 'highlight': {
        builder.add(pos, targetEnd, Decoration.mark({ class: `${cls} ann-highlight` }))
        break
      }
    }
  }

  return builder.finish()
}

export const annotationPlugin = ViewPlugin.fromClass(
  class {
    decorations: DecorationSet

    constructor(view: EditorView) {
      this.decorations = buildDecorations(view)
    }

    update(update: ViewUpdate): void {
      if (update.docChanged || update.viewportChanged) {
        this.decorations = buildDecorations(update.view)
      }
    }
  },
  { decorations: v => v.decorations },
)
