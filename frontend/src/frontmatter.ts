// YAML frontmatter is kept out of the Tiptap document: it is split off before
// parsing, shown as a read-only box, and glued back on when the file is saved.

export interface FrontmatterSplit {
  /** The exact source text of the frontmatter block, including trailing blank lines. */
  raw: string
  /** Everything after it. */
  body: string
  entries: Array<[string, string]>
}

const BLOCK = /^---\n([\s\S]*?)\n---[ \t]*(?:\n|$)/

function clean(value: string): string {
  let v = value.trim()
  if (/^[|>][+-]?$/.test(v)) return ''
  if (v.startsWith('[') && v.endsWith(']')) v = v.slice(1, -1)
  return v.replace(/^(["'])(.*)\1$/, '$2').trim()
}

/** Top-level `key: value` pairs; list items and indented continuations are joined onto the previous key. */
function parseEntries(yaml: string): Array<[string, string]> {
  const entries: Array<[string, string]> = []
  for (const line of yaml.split('\n')) {
    if (!line.trim() || /^\s*#/.test(line)) continue
    const kv = /^([^\s:#-][^:]*):\s*(.*)$/.exec(line)
    if (kv) {
      entries.push([kv[1].trim(), clean(kv[2])])
    } else if (entries.length) {
      const part = clean(line.trim().replace(/^-\s+/, ''))
      const last = entries[entries.length - 1]
      if (part) last[1] = last[1] ? `${last[1]}, ${part}` : part
    }
  }
  return entries
}

export function splitFrontmatter(source: string): FrontmatterSplit | null {
  const m = BLOCK.exec(source)
  if (!m) return null
  const rest = source.slice(m[0].length)
  const blank = /^\n*/.exec(rest)![0]
  return {
    raw: m[0] + blank,
    body: rest.slice(blank.length),
    entries: parseEntries(m[1]),
  }
}

/** Create or update the box shown above the document; `null` removes it. */
export function renderFrontmatter(container: HTMLElement, entries: Array<[string, string]> | null): void {
  let box = container.querySelector<HTMLElement>(':scope > #frontmatter-box')
  container.classList.toggle('has-frontmatter', entries !== null)
  if (entries === null) {
    box?.remove()
    return
  }
  if (!box) {
    box = document.createElement('div')
    box.id = 'frontmatter-box'
    container.prepend(box)
  }
  const table = document.createElement('table')
  for (const [key, value] of entries) {
    const row = table.insertRow()
    row.insertCell().textContent = key
    row.insertCell().textContent = value
  }
  box.replaceChildren(table)
}
