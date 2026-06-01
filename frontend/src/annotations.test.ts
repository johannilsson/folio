import { describe, it, expect } from 'vitest'
import { findAnchor } from './annotations'

// Minimal ProseMirror-compatible document mock. findAnchor only calls
// doc.descendants and reads node.isText / node.text — no DOM needed.
function mockDoc(nodes: Array<{ text: string; pos: number }>) {
  return {
    descendants(cb: (node: { isText: boolean; text?: string }, pos: number) => void) {
      for (const { text, pos } of nodes) {
        cb({ isText: true, text }, pos)
      }
    },
  }
}

// Two consecutive paragraphs. Block gap = 2 (close para + open para).
// First text node at pos 1; each subsequent text node at pos = prev_pos + prev_len + 2.
function paragraphs(...texts: string[]) {
  const nodes: Array<{ text: string; pos: number }> = []
  let pos = 1
  for (const text of texts) {
    nodes.push({ text, pos })
    pos += text.length + 2
  }
  return mockDoc(nodes)
}

// Bullet list items. Block gap = 4 (close para, close LI, open LI, open para).
// First text node at pos 3 (bulletList + listItem + para each add 1).
function bulletList(...items: string[]) {
  const nodes: Array<{ text: string; pos: number }> = []
  let pos = 3
  for (let i = 0; i < items.length; i++) {
    nodes.push({ text: items[i], pos })
    pos += items[i].length + 4
  }
  return mockDoc(nodes)
}

describe('findAnchor', () => {
  describe('basic matching', () => {
    it('finds a target in the middle of a paragraph', () => {
      // "Hello world": H=1 e=2 l=3 l=4 o=5 ' '=6 w=7 o=8 r=9 l=10 d=11
      // context "Hello " = 6 chars → fromIdx=6 → charPos[6]=7; "world"=5 → to=charPos[10]+1=12
      const doc = paragraphs('Hello world')
      expect(findAnchor(doc as any, 'Hello ', 'world')).toEqual({ from: 7, to: 12 })
    })

    it('returns null when context and target are not present', () => {
      const doc = paragraphs('Hello world')
      expect(findAnchor(doc as any, 'missing', 'text')).toBeNull()
    })

    it('matches case-insensitively', () => {
      const doc = paragraphs('Hello World')
      expect(findAnchor(doc as any, 'HELLO ', 'WORLD')).toEqual({ from: 7, to: 12 })
    })

    it('returns from === to for insert/comment annotations (no target)', () => {
      const doc = paragraphs('Hello world')
      const result = findAnchor(doc as any, 'Hello ', null)
      expect(result).not.toBeNull()
      expect(result!.from).toBe(result!.to)
    })
  })

  describe('multi-block documents', () => {
    it('finds a target in the middle of a list item', () => {
      // "item one" at pos 3: i=3 t=4 e=5 m=6 ' '=7 o=8 n=9 e=10
      // context "item " (5 chars) → fromIdx=5 → charPos[5]=8
      // target "on" (2 chars) → toIdx=7 → to=charPos[6]+1=10
      const doc = bulletList('item one', 'item two')
      const result = findAnchor(doc as any, 'item ', 'on')
      expect(result).not.toBeNull()
      expect(result!.from).toBe(8)
      expect(result!.to).toBe(10)
    })

    it('places `to` inside the same list item when the target ends at the block boundary', () => {
      // "item one" at pos 3 (chars 3–10), "item two" at pos 15 (chars 15–22).
      // target "one" is the last word of the first list item.
      //
      // Bug (before fix): toIdx=8 → charPos[8]=15 (start of "item two") — wrong block.
      // Fix:              to = charPos[7]+1 = 10+1 = 11 — stays inside first item.
      const doc = bulletList('item one', 'item two')
      const result = findAnchor(doc as any, 'item ', 'one')
      expect(result).not.toBeNull()
      expect(result!.from).toBe(8)
      expect(result!.to).toBe(11)    // must NOT be 15 (the start of the next list item)
    })

    it('does not place `to` at the ProseMirror position of the next block', () => {
      const doc = bulletList('item one', 'item two')
      const result = findAnchor(doc as any, 'item ', 'one')
      // Position 15 is the first character of "item two" — to must never land there.
      expect(result!.to).not.toBe(15)
    })
  })

  describe('targets spanning multiple text nodes in one block', () => {
    it('handles bold text followed by regular text in the same paragraph', () => {
      // Simulates <strong>Cover crops</strong> between rows:
      // two consecutive text nodes (no positional gap — same paragraph).
      // "Cover crops" at pos 1 (chars 1–11), " between rows" at pos 12 (chars 12–24).
      // context "Cover " (6 chars) → from=charPos[6]=7
      // target "crops between" (13 chars) → toIdx=19 → to=charPos[18]+1=19+1=20
      const doc = mockDoc([
        { text: 'Cover crops', pos: 1 },
        { text: ' between rows', pos: 12 },
      ])
      const result = findAnchor(doc as any, 'Cover ', 'crops between')
      expect(result).not.toBeNull()
      expect(result!.from).toBe(7)
      expect(result!.to).toBe(20)
    })
  })
})
