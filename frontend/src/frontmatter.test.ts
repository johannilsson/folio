import { describe, it, expect } from 'vitest'
import { splitFrontmatter } from './frontmatter'

describe('splitFrontmatter', () => {
  it('returns null without frontmatter', () => {
    expect(splitFrontmatter('# Title\n\ntext')).toBeNull()
    expect(splitFrontmatter('text\n---\na: b\n---\n')).toBeNull()
  })

  it('splits losslessly and parses entries', () => {
    const src = '---\ntitle: "Hello"\ntags: [a, b]\nauthors:\n  - Ann\n  - Bo\n---\n\n# Body\n'
    const r = splitFrontmatter(src)!
    expect(r.raw + r.body).toBe(src)
    expect(r.body).toBe('# Body\n')
    expect(r.entries).toEqual([['title', 'Hello'], ['tags', 'a, b'], ['authors', 'Ann, Bo']])
  })

  it('handles a frontmatter-only file', () => {
    const r = splitFrontmatter('---\na: 1\n---')!
    expect(r.body).toBe('')
    expect(r.entries).toEqual([['a', '1']])
  })
})
