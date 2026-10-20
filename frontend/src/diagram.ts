// The page the native preview draws mermaid diagrams with: a hidden web view loads it, asks for a
// diagram by calling `window.__folioMermaid`, and takes a picture of what is drawn.
import mermaid from 'mermaid'
import { mermaidConfig } from './mermaid-config'

let counter = 0

declare global {
  interface Window {
    __folioMermaid: (code: string, dark: boolean) => Promise<[number, number]>
  }
}

// Draws the diagram, and returns the size of the picture to take.
window.__folioMermaid = async (code, dark) => {
  mermaid.initialize(mermaidConfig(dark ? 'dark' : 'default'))
  const { svg } = await mermaid.render(`diagram-${++counter}`, code)
  document.body.style.cssText = `margin:0;background:${dark ? '#1a1a1a' : '#ffffff'}`
  document.body.innerHTML = `<div id="drawn" style="display:inline-block;padding:8px">${svg}</div>`
  const box = document.getElementById('drawn')!.getBoundingClientRect()
  return [Math.ceil(box.width), Math.ceil(box.height)]
}
