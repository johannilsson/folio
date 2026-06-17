export const getInfo = (): Promise<{ filename: string; plantumlUrl: string }> =>
  fetch('/api/info').then(r => r.json())

export const getFile = (): Promise<string> =>
  fetch('/api/file').then(r => r.text())

export const putFile = (content: string): Promise<Response> =>
  fetch('/api/file', { method: 'PUT', body: content })

export const getFolio = (): Promise<Sidecar> =>
  fetch('/api/folio').then(r => r.json())

export const putFolio = (sidecar: Sidecar): Promise<Response> =>
  fetch('/api/folio', {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(sidecar, null, 2),
  })

export const getKrokiUrl = (): Promise<string> =>
  fetch('/api/kroki-url').then(r => r.json()).then(d => d.url)

export interface AnchorRequestItem {
  id: string
  context_before: string
  target?: string
}

export interface AnchorResultItem {
  id: string
  char_from?: number
  char_to?: number
}

export const postAnchor = (items: AnchorRequestItem[]): Promise<AnchorResultItem[]> =>
  fetch('/api/anchor', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(items),
  }).then(r => r.json())

export interface ThreadReply {
  id: string
  author: string
  source: 'local' | 'agent' | 'github' | 'gitlab'
  body: string
  created: string
}

export interface Annotation {
  id: string
  kind: 'replace' | 'delete' | 'insert' | 'comment' | 'highlight'
  source: 'local' | 'agent' | 'github' | 'gitlab'
  author: string
  context_before: string
  target?: string | null
  replacement?: string | null
  comment?: string | null
  created: string
  resolved: boolean
  resolved_as?: string | null
  resolved_at?: string | null
  replies?: ThreadReply[]
}

export interface Sidecar {
  version: number
  annotations: Annotation[]
}
