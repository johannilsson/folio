import type { Editor, JSONContent } from '@tiptap/core'
import type { Node as PMNode } from '@tiptap/pm/model'

// Block-level source sync for the Tiptap preview editor.
//
// Tiptap can only produce markdown by re-serializing the whole document, which
// reformats everything the user didn't touch. Instead we keep the original
// source split into top-level blocks, each paired with the ProseMirror node it
// parsed into. On every edit we diff the new top-level nodes against the old
// ones; blocks whose node is unchanged keep their original text byte-for-byte,
// and only changed/new blocks are serialized.

export interface Codec {
  lex(src: string): Array<{ type: string; raw: string }>
  /** Parse markdown into top-level ProseMirror nodes. */
  parse(markdown: string): PMNode[]
  /** Serialize a single top-level node to markdown (no trailing whitespace). */
  serialize(node: PMNode): string
}

interface Block {
  node: PMNode
  body: string
  /** Whitespace between this block and the next, as in the original source. */
  tail: string
}

export interface SyncState {
  /** Blank lines before the first block. */
  head: string
  blocks: Block[]
  /** Trailing whitespace of the file (kept off the last block's `tail`). */
  finalTail: string
}

const isEmptyParagraph = (n: PMNode) => n.type.name === 'paragraph' && n.childCount === 0

/** Split `raw` into `count` pieces, each ending after a blank line; the remainder goes on the last. */
function splitSeparators(raw: string, count: number): string[] {
  const pieces: string[] = []
  let rest = raw
  for (let i = 0; i < count - 1; i++) {
    const at = rest.indexOf('\n\n')
    if (at < 0) break
    pieces.push(rest.slice(0, at + 2))
    rest = rest.slice(at + 2)
  }
  pieces.push(rest)
  while (pieces.length < count) pieces.push('')
  return pieces
}

/**
 * Pair the source's top-level blocks with the nodes of `doc`. Returns a reason
 * string when they don't line up (frontmatter, reference definitions, HTML
 * blocks, CRLF, …) — callers must then keep the document read-only, because
 * there is no way to save edits without reformatting the file.
 *
 * Tiptap turns extra blank lines into empty paragraphs; those become blocks
 * with an empty body whose text lives entirely in the surrounding separators.
 */
export function buildState(source: string, doc: PMNode, codec: Codec): SyncState | string {
  const tokens = codec.lex(source)
  if (tokens.map(t => t.raw).join('') !== source) {
    return 'the source contains line endings or whitespace the markdown parser normalizes (e.g. CRLF)'
  }

  // Merge adjacent space tokens so the list alternates content / whitespace.
  const segments: Array<{ type: string; raw: string }> = []
  for (const t of tokens) {
    const prev = segments[segments.length - 1]
    if (t.type === 'space' && prev?.type === 'space') prev.raw += t.raw
    else segments.push({ type: t.type, raw: t.raw })
  }

  if (segments.every(s => s.type === 'space') && doc.childCount === 1 && isEmptyParagraph(doc.child(0))) {
    return { head: '', blocks: [{ node: doc.child(0), body: '', tail: '' }], finalTail: source }
  }

  let head = ''
  const blocks: Block[] = []
  let child = 0
  for (let i = 0; i < segments.length; i++) {
    const seg = segments[i]
    if (seg.type !== 'space') {
      if (child >= doc.childCount) return `the editor has fewer blocks than the source (stopped at a "${seg.type}" block)`
      const body = seg.raw.replace(/\n+$/, '')
      const nodes = codec.parse(body)
      if (nodes.length !== 1 || !nodes[0].eq(doc.child(child))) {
        return `a "${seg.type}" block near "${body.slice(0, 30).replace(/\n/g, ' ')}" does not round-trip through the editor`
      }
      blocks.push({ node: doc.child(child), body, tail: seg.raw.slice(body.length) })
      child++
      continue
    }
    let empties = 0
    while (child + empties < doc.childCount && isEmptyParagraph(doc.child(child + empties))) empties++
    const prev = blocks[blocks.length - 1]
    if (!prev) {
      if (empties === 0) head += seg.raw
      else splitSeparators(seg.raw, empties).forEach((tail, j) => blocks.push({ node: doc.child(child + j), body: '', tail }))
    } else {
      const pieces = splitSeparators(seg.raw, empties + 1)
      prev.tail += pieces[0]
      for (let j = 0; j < empties; j++) blocks.push({ node: doc.child(child + j), body: '', tail: pieces[j + 1] })
    }
    child += empties
  }

  if (child !== doc.childCount) {
    return `the editor has ${doc.childCount - child} more blocks than the source`
  }

  const last = blocks[blocks.length - 1]
  const finalTail = last?.tail ?? ''
  if (last) last.tail = ''
  return { head, blocks, finalTail }
}

/** Bring `state` up to date with `doc` after an edit, re-serializing only changed blocks. */
export function reconcile(state: SyncState, doc: PMNode, codec: Codec): SyncState {
  const next: PMNode[] = []
  doc.forEach(n => next.push(n))
  const old = state.blocks

  let prefix = 0
  while (prefix < old.length && prefix < next.length && old[prefix].node.eq(next[prefix])) prefix++
  let suffix = 0
  while (
    suffix < old.length - prefix &&
    suffix < next.length - prefix &&
    old[old.length - 1 - suffix].node.eq(next[next.length - 1 - suffix])
  ) suffix++

  const oldMid = old.slice(prefix, old.length - suffix)
  const middle = next.slice(prefix, next.length - suffix).map((node, i): Block => {
    const same = oldMid.find(b => b.node.eq(node))
    if (same) return { node, body: same.body, tail: same.tail }
    return { node, body: codec.serialize(node), tail: oldMid[i]?.tail ?? '' }
  })

  return {
    ...state,
    blocks: [...old.slice(0, prefix), ...middle, ...old.slice(old.length - suffix)],
  }
}

export function joinState(state: SyncState, normalizeSeparators = false): string {
  const last = state.blocks.length - 1
  let out = state.head
  state.blocks.forEach((b, i) => {
    out += b.body
    if (i === last) out += state.finalTail
    else out += normalizeSeparators ? '\n\n' : b.tail || '\n\n'
  })
  return out
}

/** True if re-lexing `source` yields exactly the blocks in `state` (nothing merged or split). */
export function matchesBlocks(source: string, state: SyncState, codec: Codec): boolean {
  return codec.lex(source).filter(t => t.type !== 'space').length === state.blocks.filter(b => b.body !== '').length
}

export function decodeHtmlEntities(s: string): string {
  return s
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&apos;/g, "'")
}

interface MarkdownManager {
  instance: { lexer(src: string): Array<{ type: string; raw: string }> }
  parse(markdown: string): JSONContent
  serialize(doc: JSONContent): string
}

export function createCodec(editor: Editor): Codec {
  const manager = (editor.storage.markdown as { manager: MarkdownManager }).manager
  return {
    lex: src => manager.instance.lexer(src),
    parse: md => (manager.parse(md).content ?? []).map(json => editor.schema.nodeFromJSON(json)),
    serialize: node =>
      decodeHtmlEntities(manager.serialize({ type: 'doc', content: [node.toJSON()] })).replace(/\s+$/, ''),
  }
}
