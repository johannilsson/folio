// How mermaid is drawn, in Folio's colours: the editor page's diagrams and the native preview's (diagram.ts) share it.
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
