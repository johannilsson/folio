import { describe, it, expect } from 'vitest'
import { Editor } from '@tiptap/core'
import StarterKit from '@tiptap/starter-kit'
import { Markdown } from '@tiptap/markdown'
import { TableKit } from '@tiptap/extension-table'
import { buildState, reconcile, joinState, matchesBlocks, createCodec } from './source-sync'
import type { SyncState } from './source-sync'

function makeEditor(source: string) {
  return new Editor({
    extensions: [StarterKit, TableKit, Markdown],
    content: source,
    contentType: 'markdown',
  })
}

function load(source: string) {
  const editor = makeEditor(source)
  const codec = createCodec(editor)
  const state = buildState(source, editor.state.doc, codec)
  return { editor, codec, state }
}

// Apply an edit via ProseMirror and return the synced source.
function edit(source: string, fn: (editor: Editor) => void): string {
  const { editor, codec, state } = load(source)
  if (typeof state === 'string') throw new Error(`not aligned: ${state}`)
  fn(editor)
  return joinState(reconcile(state, editor.state.doc, codec))
}

// Position just after `text` inside the document.
function posAfter(editor: Editor, text: string): number {
  let found = -1
  editor.state.doc.descendants((node, pos) => {
    if (found >= 0 || !node.isText) return
    const i = node.text!.indexOf(text)
    if (i >= 0) found = pos + i + text.length
  })
  if (found < 0) throw new Error(`text not found: ${text}`)
  return found
}

const messy = [
  '# Title',
  '',
  'Some *emphasis* and __strong__ text   with  odd spacing.',
  '',
  '* star bullet one',
  '* star bullet two',
  '',
  '| a | b |',
  '|---|---|',
  '| 1 | 2 |',
  '',
  '```js',
  'const  x  =  1',
  '```',
  '',
  'Last paragraph.',
  '',
].join('\n')

describe('buildState / joinState', () => {
  it('round-trips an unedited document byte-for-byte', () => {
    const { state } = load(messy)
    expect(typeof state).not.toBe('string')
    expect(joinState(state as SyncState)).toBe(messy)
  })

  it('round-trips unusual whitespace byte-for-byte', () => {
    const sources = [
      'Hello\n\nWorld',
      'Hello\n\nWorld\n\n\n',
      '\n\nHello\n\nWorld\n',
      'One\n\n\n\n\nTwo\n',
      'Trailing space. \n\nNext\n',
      '',
      '\n',
    ]
    for (const src of sources) {
      const { state } = load(src)
      expect(typeof state, JSON.stringify(src)).not.toBe('string')
      expect(joinState(state as SyncState), JSON.stringify(src)).toBe(src)
    }
  })

  it('preserves tight spacing between heading and paragraph', () => {
    const src = '# H\ntext\n'
    const { state } = load(src)
    expect(typeof state).not.toBe('string')
    expect(joinState(state as SyncState)).toBe(src)
  })

  it('reports why a document cannot be synced (CRLF)', () => {
    const { state } = load('a\r\n\r\nb\r\n')
    expect(typeof state).toBe('string')
  })

  it('reports why a document cannot be synced (reference definition)', () => {
    const { state } = load('See [x][1].\n\n[1]: http://example.com\n')
    expect(typeof state).toBe('string')
  })
})

describe('reconcile', () => {
  it('only rewrites the edited block', () => {
    const out = edit(messy, ed => {
      ed.commands.insertContentAt(posAfter(ed, 'Last paragraph'), ' edited')
    })
    expect(out).toBe(messy.replace('Last paragraph.', 'Last paragraph edited.'))
  })

  it('keeps original formatting of untouched blocks when a middle block changes', () => {
    const out = edit(messy, ed => {
      ed.commands.insertContentAt(posAfter(ed, 'star bullet one'), '!')
    })
    expect(out).toContain('Some *emphasis* and __strong__ text   with  odd spacing.')
    expect(out).toContain('const  x  =  1')
    expect(out).toContain('| a | b |\n|---|---|\n| 1 | 2 |')
    expect(out).toContain('star bullet one!')
  })

  it('restores the original text when an edit is reverted', () => {
    const { editor, codec, state } = load(messy)
    let s = state as SyncState
    const pos = posAfter(editor, 'Last paragraph')
    editor.commands.insertContentAt(pos, 'X')
    s = reconcile(s, editor.state.doc, codec)
    expect(joinState(s)).not.toBe(messy)
    editor.commands.deleteRange({ from: pos, to: pos + 1 })
    s = reconcile(s, editor.state.doc, codec)
    expect(joinState(s)).toBe(messy)
  })

  it('handles inserting a new paragraph', () => {
    const src = 'One\n\nThree\n'
    const out = edit(src, ed => {
      ed.commands.insertContentAt(posAfter(ed, 'One') + 1, { type: 'paragraph', content: [{ type: 'text', text: 'Two' }] })
    })
    expect(out).toBe('One\n\nTwo\n\nThree\n')
  })

  it('handles appending after the last block', () => {
    const src = 'One\n'
    const out = edit(src, ed => {
      ed.commands.insertContentAt(ed.state.doc.content.size, { type: 'paragraph', content: [{ type: 'text', text: 'Two' }] })
    })
    expect(out).toBe('One\n\nTwo\n')
  })

  it('handles deleting a block', () => {
    const src = 'One\n\nTwo\n\nThree\n'
    const out = edit(src, ed => {
      const from = posAfter(ed, 'One') + 1
      ed.commands.deleteRange({ from, to: posAfter(ed, 'Two') + 1 })
    })
    expect(out).toBe('One\n\nThree\n')
  })

  it('keeps extra blank lines when editing the paragraph before them', () => {
    const src = 'One\n\n\n\nTwo\n'
    const out = edit(src, ed => {
      ed.commands.insertContentAt(posAfter(ed, 'One'), '!')
    })
    expect(out).toBe('One!\n\n\n\nTwo\n')
  })

  it('writes typed text into an empty document', () => {
    const out = edit('', ed => {
      ed.commands.insertContentAt(1, 'Hi')
    })
    expect(out).toBe('Hi')
  })

  it('handles deleting the last block', () => {
    const src = 'One\n\nTwo\n'
    const out = edit(src, ed => {
      ed.commands.deleteRange({ from: posAfter(ed, 'One') + 1, to: ed.state.doc.content.size })
    })
    expect(out).toBe('One\n')
  })
})

describe('matchesBlocks', () => {
  it('detects blocks that would merge when joined', () => {
    const { state } = load('One\n\nTwo\n')
    const s = state as SyncState
    expect(matchesBlocks(joinState(s), s, createCodec(makeEditor('')))).toBe(true)
    const tight = { ...s, blocks: s.blocks.map(b => ({ ...b, tail: '\n' })) }
    expect(matchesBlocks(joinState(tight), tight, createCodec(makeEditor('')))).toBe(false)
    expect(matchesBlocks(joinState(tight, true), tight, createCodec(makeEditor('')))).toBe(true)
  })
})
