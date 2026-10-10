import { describe, it, expect } from 'vitest'
import { buildCharPos, charIndexToRange } from './annotations'

// Minimal ProseMirror-compatible document mock. buildCharPos only calls
// doc.descendants and reads node.type.name / node.isText / node.text — no DOM needed.
function mockDoc(nodes: Array<{ text: string; pos: number }>) {
  return {
    descendants(cb: (node: { type: { name: string }; isText: boolean; text?: string }, pos: number) => void) {
      for (const { text, pos } of nodes) {
        cb({ type: { name: 'text' }, isText: true, text }, pos)
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

describe('buildCharPos', () => {
  it('maps each character to its ProseMirror position', () => {
    // "Hello world" at pos 1: H=1 e=2 l=3 l=4 o=5 ' '=6 w=7 o=8 r=9 l=10 d=11
    const doc = paragraphs('Hello world')
    const charPos = buildCharPos(doc as any)
    expect(charPos).toEqual([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11])
  })

  it('concatenates text nodes across block boundaries with no gap in charPos', () => {
    // Two paragraphs: "abc" at pos 1, "def" at pos 1+3+2=6
    const doc = paragraphs('abc', 'def')
    const charPos = buildCharPos(doc as any)
    expect(charPos).toEqual([1, 2, 3, 6, 7, 8])
  })
})

describe('charIndexToRange', () => {
  describe('basic mapping', () => {
    it('maps a target in the middle of a paragraph', () => {
      // "Hello world": H=1 e=2 l=3 l=4 o=5 ' '=6 w=7 o=8 r=9 l=10 d=11
      // context "Hello " = 6 chars → fromIdx=6 → charPos[6]=7
      // target "world" = 5 chars → toIdx=11 → charPos[10]+1=12
      const doc = paragraphs('Hello world')
      const charPos = buildCharPos(doc as any)
      expect(charIndexToRange(charPos, 6, 11)).toEqual({ from: 7, to: 12 })
    })

    it('returns from === to for insert/comment annotations (fromIdx === toIdx)', () => {
      // context "Hello " ends at charPos[5]+1 = 6+1 = 7
      const doc = paragraphs('Hello world')
      const charPos = buildCharPos(doc as any)
      const result = charIndexToRange(charPos, 6, 6)
      expect(result.from).toBe(7)
      expect(result.from).toBe(result.to)
    })
  })

  describe('multi-block documents', () => {
    it('maps a target inside a list item', () => {
      // "item one" at pos 3: i=3 t=4 e=5 m=6 ' '=7 o=8 n=9 e=10
      // fromIdx=5 ("o") → charPos[5]=8; toIdx=7 → charPos[6]+1=9+1=10
      const doc = bulletList('item one', 'item two')
      const charPos = buildCharPos(doc as any)
      expect(charIndexToRange(charPos, 5, 7)).toEqual({ from: 8, to: 10 })
    })

    it('keeps `to` inside the first list item when the target ends at the block boundary', () => {
      // "item one" at pos 3 (chars 0–7), "item two" at pos 15 (chars 8–15).
      // target "one" is the last 3 chars of the first item.
      // toIdx=8: charPos[7]+1 = 10+1 = 11 — stays inside first item.
      // Must NOT be 15 (the start of "item two").
      const doc = bulletList('item one', 'item two')
      const charPos = buildCharPos(doc as any)
      const result = charIndexToRange(charPos, 5, 8)
      expect(result.from).toBe(8)
      expect(result.to).toBe(11)
      expect(result.to).not.toBe(15)
    })
  })

  describe('cross-block: from at start of new block', () => {
    it('places from at the first char of the next block when context_before is the full heading text', () => {
      // "## Header\n\n- First bullet text": heading "Header" at pos 1, bullet at pos 11.
      // fromIdx=6 → charPos[6]=11 (first char of bullet).
      const doc = mockDoc([
        { text: 'Header', pos: 1 },
        { text: 'First bullet text', pos: 11 },
      ])
      const charPos = buildCharPos(doc as any)
      const result = charIndexToRange(charPos, 6, 11)
      expect(result.from).toBe(11)
      expect(result.from).toBeGreaterThanOrEqual(11)
    })

    it('places an insert/comment point at the end of the heading, not the start of the bullet', () => {
      // fromIdx === toIdx === 6 → from = charPos[5]+1 = 6+1 = 7 (inside heading block).
      const doc = mockDoc([
        { text: 'Header', pos: 1 },
        { text: 'First bullet text', pos: 11 },
      ])
      const charPos = buildCharPos(doc as any)
      const result = charIndexToRange(charPos, 6, 6)
      expect(result.from).toBe(7)
      expect(result.to).toBe(7)
      expect(result.from).not.toBe(11) // must not jump into the bullet block
    })

    it('insert/comment at a paragraph-to-table boundary stays in the paragraph', () => {
      // Simulates "...several months.\n\n| Style |..."
      const paraText = 'can macerate for anywhere from a few days to several months.'
      const tableStart = 1 + paraText.length + 5
      const doc = mockDoc([
        { text: paraText, pos: 1 },
        { text: 'Style', pos: tableStart },
      ])
      const charPos = buildCharPos(doc as any)
      const result = charIndexToRange(charPos, paraText.length, paraText.length)
      expect(result.from).toBe(paraText.length + 1) // charPos[last para char] + 1
      expect(result.to).toBe(result.from)
      expect(result.from).not.toBe(tableStart) // must not land in the table
    })
  })

  describe('targets spanning multiple text nodes in one block', () => {
    it('handles bold text followed by regular text in the same paragraph', () => {
      // Simulates <strong>Cover crops</strong> between rows:
      // "Cover crops" at pos 1 (chars 0–10), " between rows" at pos 12 (chars 11–23).
      // fromIdx=6 ("c" of "crops") → charPos[6]=7
      // toIdx=19 → charPos[18]+1=19+1=20
      const doc = mockDoc([
        { text: 'Cover crops', pos: 1 },
        { text: ' between rows', pos: 12 },
      ])
      const charPos = buildCharPos(doc as any)
      expect(charIndexToRange(charPos, 6, 19)).toEqual({ from: 7, to: 20 })
    })
  })
})
