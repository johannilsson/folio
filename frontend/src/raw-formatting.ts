import { EditorSelection } from '@codemirror/state'
import type { Extension } from '@codemirror/state'
import { keymap } from '@codemirror/view'
import type { Command, EditorView } from '@codemirror/view'

// Wraps each selection range in `marker` (e.g. "**" for bold), or unwraps it
// if the range is already surrounded by `marker` — a toggle, matching how
// bold/italic shortcuts behave in rich text editors. With an empty selection,
// inserts a paired marker and places the cursor between them.
export function toggleMarker(marker: string): Command {
  return (view: EditorView): boolean => {
    const tr = view.state.changeByRange(range => {
      const { from, to } = range
      if (from === to) {
        return {
          changes: { from, insert: marker + marker },
          range: EditorSelection.cursor(from + marker.length),
        }
      }
      const before = view.state.sliceDoc(from - marker.length, from)
      const after = view.state.sliceDoc(to, to + marker.length)
      if (before === marker && after === marker) {
        return {
          changes: [
            { from: from - marker.length, to: from },
            { from: to, to: to + marker.length },
          ],
          range: EditorSelection.range(from - marker.length, to - marker.length),
        }
      }
      return {
        changes: [{ from, insert: marker }, { from: to, insert: marker }],
        range: EditorSelection.range(from + marker.length, to + marker.length),
      }
    })
    view.dispatch(view.state.update(tr, { scrollIntoView: true, userEvent: 'input' }))
    return true
  }
}

export const toggleBold = toggleMarker('**')
export const toggleItalic = toggleMarker('*')

export function rawFormattingKeymap(): Extension {
  return keymap.of([
    { key: 'Mod-b', run: toggleBold },
    { key: 'Mod-i', run: toggleItalic },
  ])
}
