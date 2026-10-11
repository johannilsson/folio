// Which document of a served set this page shows (`/?file=<id>`). Absent means the
// server's first document, so single-file mode needs no id.
let fileParam = new URLSearchParams(location.search).get('file')

/** Point every file-scoped call at another document of the set. */
export function setActiveFile(id: string): void {
  fileParam = id
}

const scoped = (url: string): string =>
  fileParam ? `${url}?file=${encodeURIComponent(fileParam)}` : url

export const getInfo = (): Promise<{ id: string; filename: string; set: string | null; plantumlUrl: string }> =>
  fetch(scoped('/api/info')).then(r => r.json())

export interface FileSummary {
  id: string
  name: string
  group: string
  pending: number
}

export const getFiles = (): Promise<FileSummary[]> =>
  fetch('/api/files').then(r => r.json())

export const getFile = (): Promise<string> =>
  fetch(scoped('/api/file')).then(r => r.text())

export const putFile = (content: string): Promise<Response> =>
  fetch(scoped('/api/file'), { method: 'PUT', body: content })

export const getFolio = (): Promise<Sidecar> =>
  fetch(scoped('/api/folio')).then(r => r.json())

export const putFolio = (sidecar: Sidecar): Promise<Response> =>
  fetch(scoped('/api/folio'), {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(sidecar, null, 2),
  })

export const postAccept = (id: string): Promise<Response> =>
  fetch(scoped('/api/accept'), {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ id }),
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
  fetch(scoped('/api/anchor'), {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(items),
  }).then(r => r.json())

export const postAnchorRaw = (items: AnchorRequestItem[]): Promise<AnchorResultItem[]> =>
  fetch(scoped('/api/anchor-raw'), {
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
