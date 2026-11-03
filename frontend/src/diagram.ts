// The page the native preview gets its diagrams and code colours from: a hidden web view loads it.
// It asks for a diagram by calling `window.__folioMermaid` and takes a picture of what is drawn, and
// for the colours of a block of code by calling `window.__folioHighlight`.
import { all, createLowlight } from 'lowlight'
import mermaid from 'mermaid'
import { mermaidConfig } from './mermaid-config'
import { dark as darkTokens, light as lightTokens } from './tokens'

const lowlight = createLowlight(all)

let counter = 0

declare global {
  interface Window {
    __folioMermaid: (code: string, dark: boolean) => Promise<[number, number]>
    __folioHighlight: (code: string, language: string) => [number, number, string][]
  }
}

interface Tree {
  type: string
  value?: string
  properties?: { className?: string[] }
  children?: Tree[]
}

// The scopes of a block of code: where each coloured piece starts and ends (UTF-16 units, as the
// app counts) and its highlight.js scope, such as "keyword". A language that is not known has none.
window.__folioHighlight = (code, language) => {
  if (!language || !lowlight.registered(language)) return []
  const spans: [number, number, string][] = []
  let offset = 0
  const walk = (node: Tree, scope: string | null): void => {
    if (node.type === 'text') {
      const length = (node.value ?? '').length
      if (scope) spans.push([offset, offset + length, scope])
      offset += length
      return
    }
    const name = node.properties?.className?.find(c => c.startsWith('hljs-'))
    for (const child of node.children ?? []) walk(child, name ? name.slice(5) : scope)
  }
  walk(lowlight.highlight(language, code) as unknown as Tree, null)
  return spans
}

// Draws the diagram, and returns the size of the picture to take.
window.__folioMermaid = async (code, dark) => {
  mermaid.initialize(mermaidConfig(dark ? 'dark' : 'default'))
  const { svg } = await mermaid.render(`diagram-${++counter}`, code)
  document.body.style.cssText = `margin:0;background:${(dark ? darkTokens : lightTokens).background}`
  document.body.innerHTML = `<div id="drawn" style="display:inline-block;padding:8px">${svg}</div>`
  const box = document.getElementById('drawn')!.getBoundingClientRect()
  return [Math.ceil(box.width), Math.ceil(box.height)]
}
