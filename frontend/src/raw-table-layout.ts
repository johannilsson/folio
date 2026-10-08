import { StateField } from '@codemirror/state'
import type { Extension, Range, Text } from '@codemirror/state'
import { Decoration, EditorView, ViewPlugin } from '@codemirror/view'
import type { DecorationSet, PluginValue } from '@codemirror/view'

// Leading-pipe markdown table row (header, separator, or data).
const TABLE_ROW = /^\s*\|/

const tableRowMark = Decoration.line({ class: 'cm-table-row' })

function buildTableRowDecos(doc: Text): Range<Decoration>[] {
  const decos: Range<Decoration>[] = []
  for (let i = 1; i <= doc.lines; i++) {
    const line = doc.line(i)
    if (TABLE_ROW.test(line.text)) decos.push(tableRowMark.range(line.from))
  }
  return decos
}

const tableRowField = StateField.define<DecorationSet>({
  create: state => Decoration.set(buildTableRowDecos(state.doc)),
  update: (decos, tr) => (tr.docChanged ? Decoration.set(buildTableRowDecos(tr.state.doc)) : decos),
  provide: f => EditorView.decorations.from(f),
})

// Each `.cm-table-row` line scrolls independently (it's its own overflow
// box), so scrolling one row would otherwise misalign it from the rest of
// the table. Mirror scrollLeft across the contiguous run of table-row lines
// surrounding whichever one the user just scrolled, so the table moves as
// a unit. `scroll` doesn't bubble, so this has to listen on the capture
// phase rather than use CM6's `domEventHandlers` (which attaches on bubble).
function syncSiblingScroll(start: Element | null, dir: 'previousElementSibling' | 'nextElementSibling', scrollLeft: number): void {
  for (let sib = start; sib && sib.classList.contains('cm-table-row'); sib = sib[dir]) {
    ;(sib as HTMLElement).scrollLeft = scrollLeft
  }
}

class TableScrollSync implements PluginValue {
  private view: EditorView
  private onScroll = (event: Event): void => {
    const target = event.target as HTMLElement
    if (!target.classList?.contains('cm-table-row')) return
    syncSiblingScroll(target.previousElementSibling, 'previousElementSibling', target.scrollLeft)
    syncSiblingScroll(target.nextElementSibling, 'nextElementSibling', target.scrollLeft)
  }

  constructor(view: EditorView) {
    this.view = view
    view.contentDOM.addEventListener('scroll', this.onScroll, true)
  }

  destroy(): void {
    this.view.contentDOM.removeEventListener('scroll', this.onScroll, true)
  }
}

// Wide table rows would otherwise wrap character-by-character like prose,
// scrambling columns — `cm-table-row` (styled in index.html) keeps each row
// on one line and scrolls it horizontally instead, with sibling rows kept
// in sync so the whole table scrolls together.
export function tableRowLayout(): Extension {
  return [tableRowField, ViewPlugin.define(view => new TableScrollSync(view))]
}
