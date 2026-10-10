import type { Node } from '@tiptap/pm/model'
import { CodeBlockLowlight } from '@tiptap/extension-code-block-lowlight'
import { all, createLowlight } from 'lowlight'
import mermaid from 'mermaid'
import plantumlEncoder from 'plantuml-encoder'

const lowlight = createLowlight(all)

const FONT = "-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif"

// Concrete values mirroring the app's CSS tokens; mermaid can't resolve var().
const PALETTES = {
  dark: {
    bg: '#1a1a1a', node: '#2b2640', border: '#8b7bd8', text: '#e0e0e0',
    line: '#8b7bd8', accent: '#a78bfa', cluster: '#211e30',
  },
  light: {
    bg: '#ffffff', node: '#f1ecfc', border: '#a78bfa', text: '#1a1a1a',
    line: '#8b6fd8', accent: '#7c3aed', cluster: '#f7f4fd',
  },
}

function mermaidConfig(theme: 'dark' | 'default') {
  const p = theme === 'dark' ? PALETTES.dark : PALETTES.light
  return {
    startOnLoad: false,
    theme: 'base' as const,
    fontFamily: FONT,
    themeVariables: {
      darkMode: theme === 'dark',
      background: p.bg,
      fontFamily: FONT,
      fontSize: '13px',
      primaryColor: p.node,
      primaryTextColor: p.text,
      primaryBorderColor: p.border,
      secondaryColor: p.cluster,
      tertiaryColor: p.cluster,
      lineColor: p.line,
      textColor: p.text,
      mainBkg: p.node,
      nodeBorder: p.border,
      clusterBkg: p.cluster,
      clusterBorder: p.border,
      edgeLabelBackground: p.bg,
      titleColor: p.text,
      noteBkgColor: p.cluster,
      noteTextColor: p.text,
      noteBorderColor: p.border,
      actorBkg: p.node,
      actorBorder: p.border,
      actorTextColor: p.text,
      actorLineColor: p.line,
      signalColor: p.line,
      signalTextColor: p.text,
      labelBoxBkgColor: p.node,
      labelBoxBorderColor: p.border,
      labelTextColor: p.text,
      loopTextColor: p.text,
      activationBkgColor: p.cluster,
      activationBorderColor: p.accent,
    },
  }
}

mermaid.initialize(mermaidConfig('dark'))

export function setMermaidTheme(theme: 'dark' | 'default'): void {
  mermaid.initialize(mermaidConfig(theme))
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
