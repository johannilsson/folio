import { Editor } from '@tiptap/core'
import type { Extension } from '@tiptap/core'
import StarterKit from '@tiptap/starter-kit'
import { Markdown } from '@tiptap/markdown'
import { TableKit } from '@tiptap/extension-table'
import { DiagramCodeBlock } from './diagrams'

let editor: Editor | null = null

function decodeHtmlEntities(s: string): string {
  return s
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&apos;/g, "'")
}

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
    editable: false,
  })
}

export function setContent(content: string): void {
  if (!editor) return
  if (decodeHtmlEntities(editor.getMarkdown()) === content) return
  editor.commands.setContent(content, { contentType: 'markdown', emitUpdate: false })
}

export function getMarkdown(): string {
  return decodeHtmlEntities(editor?.getMarkdown() ?? '')
}

export function getEditor(): Editor | null {
  return editor
}
