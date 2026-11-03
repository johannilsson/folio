// How mermaid is drawn, in Folio's colours: the editor page's diagrams and the native preview's (diagram.ts) share it.
import { dark, light } from './tokens'

const FONT = "-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif"

// From design/tokens.json, which the app's colours come from too.
const palette = (t: typeof light | typeof dark) => ({
  bg: t.background, node: t.diagramNode, border: t.diagramBorder, text: t.diagramText,
  line: t.diagramLine, accent: t.diagramAccent, cluster: t.diagramCluster,
})
const PALETTES = { dark: palette(dark), light: palette(light) }

export function mermaidConfig(theme: 'dark' | 'default') {
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
