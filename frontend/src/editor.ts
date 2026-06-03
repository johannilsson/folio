import { Editor } from '@tiptap/core'
import type { Extension } from '@tiptap/core'
import StarterKit from '@tiptap/starter-kit'
import { Markdown } from '@tiptap/markdown'
import { TableKit } from '@tiptap/extension-table'
import { DiagramCodeBlock } from './diagrams'
import { putFile } from './api'

let editor: Editor | null = null
let saveTimer: ReturnType<typeof setTimeout> | null = null

export function initEditor(
  container: HTMLElement,
  initialContent: string,
  extraExtensions: Extension[] = [],
): void {
  editor = new Editor({
    element: container,
    extensions: [StarterKit.configure({ codeBlock: false }), DiagramCodeBlock, TableKit, Markdown, ...extraExtensions],
    content: initialContent,
    contentType: 'markdown',
    onUpdate({ editor: ed }) {
      const markdown = ed.getMarkdown()
      if (saveTimer) clearTimeout(saveTimer)
      saveTimer = setTimeout(() => putFile(markdown), 300)
    },
  })
}

export function setContent(content: string): void {
  if (!editor) return
  if (editor.getMarkdown() === content) return
  editor.commands.setContent(content, { contentType: 'markdown', emitUpdate: false })
}

export function getMarkdown(): string {
  return editor?.getMarkdown() ?? ''
}

export function getEditor(): Editor | null {
  return editor
}
