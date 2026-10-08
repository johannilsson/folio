import { Editor } from '@tiptap/core'
import type { Extension } from '@tiptap/core'
import StarterKit from '@tiptap/starter-kit'
import { Markdown } from '@tiptap/markdown'
import { TableKit } from '@tiptap/extension-table'
import { DiagramCodeBlock } from './diagrams'
import { putFile } from './api'
import { buildState, reconcile, joinState, matchesBlocks, createCodec, decodeHtmlEntities } from './source-sync'
import type { Codec, SyncState } from './source-sync'

let editor: Editor | null = null
let codec: Codec | null = null
// Original source split into blocks; only edited blocks are re-serialized on save.
// null = the document can't be mapped back to its source, so it stays read-only.
let sync: SyncState | null = null
// The file contents we last loaded or wrote — used to ignore echoes of our own saves.
let lastSynced = ''
let saveTimer: ReturnType<typeof setTimeout> | null = null
let statusCb: ((readOnlyReason: string | null) => void) | null = null

export function initEditor(
  container: HTMLElement,
  initialContent: string,
  extraExtensions: Extension[] = [],
  onStatus?: (readOnlyReason: string | null) => void,
): void {
  statusCb = onStatus ?? null
  editor = new Editor({
    element: container,
    extensions: [StarterKit.configure({ codeBlock: false }), DiagramCodeBlock, TableKit, Markdown, ...extraExtensions],
    content: initialContent,
    contentType: 'markdown',
    editable: false,
    onUpdate({ transaction }) {
      if (transaction.docChanged) onDocChanged()
    },
  })
  codec = createCodec(editor)
  attachSync(initialContent)
}

function lock(reason: string): void {
  sync = null
  editor?.setEditable(false, false)
  console.warn(`Preview is read-only: ${reason}`)
  statusCb?.(reason)
}

function attachSync(source: string): void {
  if (!editor || !codec) return
  lastSynced = source
  const result = buildState(source, editor.state.doc, codec)
  if (typeof result === 'string') return lock(result)
  sync = result
  editor.setEditable(true, false)
  statusCb?.(null)
}

function onDocChanged(): void {
  if (!editor || !codec || !sync) return
  sync = reconcile(sync, editor.state.doc, codec)
  if (saveTimer) clearTimeout(saveTimer)
  saveTimer = setTimeout(() => { void flushSave() }, 300)
}

/** Write any pending edits to disk. Resolves once the write has finished. */
export function flushSave(): Promise<unknown> {
  if (!saveTimer) return Promise.resolve()
  clearTimeout(saveTimer)
  saveTimer = null
  if (!sync || !codec) return Promise.resolve()

  let text = joinState(sync)
  // An edit can leave a block's original separator too tight (e.g. a paragraph
  // now directly above another paragraph) — retry with blank lines between all.
  if (!matchesBlocks(text, sync, codec)) text = joinState(sync, true)
  if (!matchesBlocks(text, sync, codec)) {
    lock('your last edit could not be saved without merging blocks; reload to continue')
    return Promise.resolve()
  }
  lastSynced = text
  return putFile(text)
}

export function setContent(content: string): void {
  if (!editor) return
  if (content === lastSynced) return
  // Unsaved local edits win: they will overwrite the file in a moment, and an
  // older echo of our own write must not clobber what the user is typing.
  if (saveTimer) return
  // Reloaded content is not something the user typed, so keep it out of undo history.
  editor.chain().setMeta('addToHistory', false).setContent(content, { contentType: 'markdown', emitUpdate: false }).run()
  attachSync(content)
}

export function getMarkdown(): string {
  return decodeHtmlEntities(editor?.getMarkdown() ?? '')
}

export function getEditor(): Editor | null {
  return editor
}
