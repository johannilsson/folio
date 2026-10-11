import { getFiles } from './api'
import type { FileSummary } from './api'

const pill = document.getElementById('title-pill')!
const button = document.getElementById('file-menu-btn') as HTMLButtonElement
const menu = document.getElementById('file-menu')!

let currentId = ''
let setName = ''
let onSelect: (id: string) => void = () => {}
let active = false

function setOpen(open: boolean): void {
  menu.hidden = !open
  button.setAttribute('aria-expanded', String(open))
}

function render(files: FileSummary[]): void {
  const card = document.createElement('div')
  card.className = 'fm-card'
  if (setName) {
    const title = document.createElement('div')
    title.className = 'fm-title'
    title.textContent = setName
    card.appendChild(title)
  }
  // Repo headings only earn their space when the set spans several roots.
  const multiRoot = new Set(files.map(f => f.group)).size > 1
  let group: string | null = null
  for (const file of files) {
    if (multiRoot && file.group !== group) {
      group = file.group
      const label = document.createElement('div')
      label.className = 'fm-group'
      label.textContent = file.group
      label.title = file.group
      card.appendChild(label)
    }
    const link = document.createElement('a')
    link.className = 'fm-item'
    link.classList.toggle('current', file.id === currentId)
    link.dataset.id = file.id
    link.href = `/?file=${encodeURIComponent(file.id)}`
    link.title = file.name
    const name = document.createElement('span')
    name.className = 'fm-name'
    name.textContent = file.name
    const badge = document.createElement('span')
    badge.className = 'fm-badge'
    badge.textContent = file.pending ? String(file.pending) : ''
    badge.hidden = file.pending === 0
    badge.title = `${file.pending} pending`
    link.append(name, badge)
    card.appendChild(link)
  }
  menu.replaceChildren(card)
}

// Links keep a real href so cmd/ctrl-click can open a file in its own tab; a plain
// click swaps the document in place.
menu.addEventListener('click', e => {
  const link = (e.target as HTMLElement).closest<HTMLAnchorElement>('a.fm-item')
  if (!link || e.metaKey || e.ctrlKey || e.shiftKey || e.button !== 0) return
  e.preventDefault()
  setOpen(false)
  onSelect(link.dataset.id!)
})

pill.addEventListener('click', e => {
  if (!active || (e.target as HTMLElement).closest('#preview-readonly-notice')) return
  setOpen(menu.hidden)
})

document.addEventListener('keydown', e => {
  if (e.key === 'Escape' && !menu.hidden) {
    setOpen(false)
    button.focus()
  }
})
document.addEventListener('mousedown', e => {
  if (menu.hidden) return
  const target = e.target as Node
  if (!menu.contains(target) && !pill.contains(target)) setOpen(false)
})

export async function refreshFileMenu(): Promise<void> {
  if (active) render(await getFiles())
}

/** Highlight the file now showing. */
export function setCurrentFile(id: string): void {
  currentId = id
  menu.querySelectorAll<HTMLElement>('.fm-item').forEach(el => {
    el.classList.toggle('current', el.dataset.id === id)
  })
}

/**
 * Turn the title pill into a menu when the server serves more than one file.
 * Resolves to whether it did.
 */
export async function initFileMenu(id: string, set: string | null, select: (id: string) => void): Promise<boolean> {
  currentId = id
  setName = set ?? ''
  onSelect = select
  const files = await getFiles()
  if (files.length < 2) return false
  active = true
  render(files)
  pill.classList.add('has-menu')
  return true
}
