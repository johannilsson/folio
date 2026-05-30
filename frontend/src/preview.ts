import MarkdownIt from 'markdown-it'

const md = new MarkdownIt({ html: false, linkify: true, typographer: true })

let krokiUrl = 'https://kroki.io'
let previewEl: HTMLElement | null = null

export function initPreview(container: HTMLElement, resolvedKrokiUrl: string): void {
  previewEl = container
  krokiUrl = resolvedKrokiUrl
}

export function renderPreview(source: string): void {
  if (!previewEl) return
  previewEl.innerHTML = md.render(source)
  renderMermaid()
  renderPlantUml()
}

function renderMermaid(): void {
  if (!previewEl) return
  const blocks = previewEl.querySelectorAll('pre > code.language-mermaid')
  if (blocks.length === 0) return

  import('mermaid').then(({ default: mermaid }) => {
    mermaid.initialize({ startOnLoad: false, theme: 'dark' })
    blocks.forEach((block, i) => {
      const code = block.textContent ?? ''
      const id = `mermaid-${i}-${Date.now()}`
      const container = document.createElement('div')
      container.className = 'mermaid-container'
      block.parentElement?.replaceWith(container)
      mermaid.render(id, code)
        .then(({ svg }) => { container.innerHTML = svg })
        .catch(err => { container.textContent = `Mermaid error: ${err}` })
    })
  })
}

function renderPlantUml(): void {
  if (!previewEl) return
  const blocks = previewEl.querySelectorAll('pre > code.language-plantuml')
  blocks.forEach(block => {
    const code = block.textContent ?? ''
    const encoded = encodePlantUml(code)
    const url = `${krokiUrl}/plantuml/svg/${encoded}`
    const img = document.createElement('img')
    img.src = url
    img.style.maxWidth = '100%'
    block.parentElement?.replaceWith(img)
  })
}

function encodePlantUml(source: string): string {
  // Deflate + base64url encoding expected by Kroki
  const bytes = new TextEncoder().encode(source)
  let binary = ''
  bytes.forEach(b => { binary += String.fromCharCode(b) })
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_')
}
