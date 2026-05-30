import { EditorView, keymap, lineNumbers, highlightActiveLine } from '@codemirror/view'
import { Extension } from '@codemirror/state'
import { EditorState } from '@codemirror/state'
import { defaultKeymap, history, historyKeymap } from '@codemirror/commands'
import { markdown } from '@codemirror/lang-markdown'
import { languages } from '@codemirror/language-data'
import { oneDark } from '@codemirror/theme-one-dark'
import { putFile } from './api'

type ChangeHandler = (content: string) => void

let view: EditorView | null = null
let saveTimer: ReturnType<typeof setTimeout> | null = null
let changeHandlers: ChangeHandler[] = []

export function initEditor(
  container: HTMLElement,
  initialContent: string,
  extraExtensions: Extension[] = [],
): void {
  const state = EditorState.create({
    doc: initialContent,
    extensions: [
      ...extraExtensions,
      lineNumbers(),
      highlightActiveLine(),
      history(),
      keymap.of([...defaultKeymap, ...historyKeymap]),
      markdown({ codeLanguages: languages }),
      oneDark,
      EditorView.lineWrapping,
      EditorView.updateListener.of(update => {
        if (!update.docChanged) return
        const content = update.state.doc.toString()
        changeHandlers.forEach(h => h(content))
        if (saveTimer) clearTimeout(saveTimer)
        saveTimer = setTimeout(() => putFile(content), 300)
      }),
    ],
  })

  view = new EditorView({ state, parent: container })
}

export function setContent(content: string): void {
  if (!view) return
  const current = view.state.doc.toString()
  if (current === content) return
  view.dispatch({
    changes: { from: 0, to: current.length, insert: content },
  })
}

export function getContent(): string {
  return view?.state.doc.toString() ?? ''
}

export function getView(): EditorView | null {
  return view
}

export function onChange(handler: ChangeHandler): void {
  changeHandlers.push(handler)
}
