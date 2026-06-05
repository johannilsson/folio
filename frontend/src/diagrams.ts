import type { Node } from '@tiptap/pm/model'
import { CodeBlockLowlight } from '@tiptap/extension-code-block-lowlight'
import { all, createLowlight } from 'lowlight'
import mermaid from 'mermaid'
import plantumlEncoder from 'plantuml-encoder'

const lowlight = createLowlight(all)

mermaid.initialize({ startOnLoad: false, theme: 'dark' })

export function setMermaidTheme(theme: 'dark' | 'default'): void {
  mermaid.initialize({ startOnLoad: false, theme })
  window.dispatchEvent(new Event('folio:theme-changed'))
}

let mermaidIdCounter = 0

async function renderMermaid(code: string): Promise<string> {
  const id = `mermaid-${++mermaidIdCounter}`
  const { svg } = await mermaid.render(id, code)
  return svg
}

let plantumlBase = 'https://www.plantuml.com/plantuml'

export function setPlantumlUrl(url: string): void {
  plantumlBase = url.replace(/\/$/, '')
}

function plantUMLUrls(source: string): { svg: string; png: string } {
  const enc = plantumlEncoder.encode(source)
  return { svg: `${plantumlBase}/svg/${enc}`, png: `${plantumlBase}/png/${enc}` }
}

export const DiagramCodeBlock = CodeBlockLowlight.configure({ lowlight }).extend({
  addNodeView() {
    return ({ node }) => {
      const lang: string = node.attrs.language ?? ''

      // Non-diagram blocks: replicate default <pre><code> rendering with editable content
      if (lang !== 'mermaid' && lang !== 'plantuml') {
        const pre = document.createElement('pre')
        const code = document.createElement('code')
        if (lang) code.className = `language-${lang}`
        pre.appendChild(code)
        return { dom: pre, contentDOM: code }
      }

      const dom = document.createElement('div')
      dom.className = 'diagram-block'
      let currentCode = ''

      function render(code: string): void {
        currentCode = code
        if (lang === 'mermaid') {
          dom.innerHTML = '<p class="diagram-loading">Rendering…</p>'
          renderMermaid(code)
            .then(svg => { if (currentCode === code) dom.innerHTML = svg })
            .catch(e => { if (currentCode === code) dom.textContent = `Mermaid error: ${e}` })
        } else {
          try {
            const { svg, png } = plantUMLUrls(code)
            const img = document.createElement('img')
            img.alt = 'PlantUML diagram'
            img.onerror = () => { img.onerror = null; img.src = png }
            img.src = svg
            dom.innerHTML = ''
            dom.appendChild(img)
          } catch (e) {
            dom.textContent = `PlantUML error: ${e}`
          }
        }
      }

      render(node.textContent)

      const onThemeChange = () => { if (lang === 'mermaid') render(currentCode) }
      window.addEventListener('folio:theme-changed', onThemeChange)

      return {
        dom,
        update(updated: Node) {
          if (updated.type !== node.type) return false
          if ((updated.attrs.language ?? '') !== lang) return false
          const newCode: string = updated.textContent
          if (newCode !== currentCode) render(newCode)
          return true
        },
        destroy() { window.removeEventListener('folio:theme-changed', onThemeChange) },
      }
    }
  },
})
