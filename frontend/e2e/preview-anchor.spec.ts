import { test, expect } from './fixtures'
import { readFileSync } from 'fs'
import { join } from 'path'

// Markdown the preview renders differently from `folio render`. The preview anchors
// against its own text, so none of it may shift a highlight further down.
const STRESS = `# Title with \`code\` and *emph*

Escapes: 1\\. not a list, \\*not emph\\*, a\\_b, back\\\\slash.

Entities: &amp; &copy; and emoji 🎉 done.

Autolink <https://example.com> here.

Line with trailing backslash\\
next line.

A paragraph that is
soft wrapped.

**Summary:**
After a hard break.

1) paren list

- [ ] task one

> quote one
>
> > nested quote

Setext heading
==============

    indented code block

| A | B |
|:--|--:|
| c \\| d | e |

Text with <span>inline html</span> and [ref link][r].

[r]: http://ref.com

Final target sentence here.
`

test('a highlight after markdown the CLI renders differently lands on its target', async ({ page, request }) => {
  const original = readFileSync(join(__dirname, 'fixture.md'), 'utf8')
  await request.put('/api/file', { data: STRESS })
  await request.put('/api/folio', { data: { version: 1, annotations: [{
    id: 'pa1', kind: 'comment', source: 'agent', author: 'agent', comment: 'Check',
    context_before: 'Final ', target: 'target sentence', created: '2026-01-01T00:00:00Z', resolved: false,
  }] } })
  try {
    await page.goto('/')
    await page.waitForSelector('.cm-content')
    await page.click('#view-toggle-btn')
    await expect(page.locator('#editor-wrapper .ann-comment-target').first()).toHaveText('target sentence')
  } finally {
    await request.put('/api/file', { data: original })
  }
})
