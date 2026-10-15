import { call, native } from './bridge'

// Which document of a served set this page shows (`/?file=<id>`). Absent means the
// server's first document, so single-file mode needs no id.
let fileParam = new URLSearchParams(location.search).get('file')

/** Point every file-scoped call at another document of the set. */
export function setActiveFile(id: string): void {
  fileParam = id
}

const scoped = (url: string): string =>
  fileParam ? `${url}?file=${encodeURIComponent(fileParam)}` : url

// File-scoped native ops carry the active document id along.
const nativeCall = <T>(op: string, payload: Record<string, unknown> = {}): Promise<T> =>
  call<T>(op, { file: fileParam, ...payload })

export const getInfo = (): Promise<{ id: string; filename: string; set: string | null; plantumlUrl: string }> =>
  native ? nativeCall('info') : fetch(scoped('/api/info')).then(r => r.json())

export interface FileSummary {
  id: string
  name: string
  group: string
  pending: number
}

export const getFiles = (): Promise<FileSummary[]> =>
  native ? nativeCall('files') : fetch('/api/files').then(r => r.json())

export const getFile = (): Promise<string> =>
  native ? nativeCall('getFile') : fetch(scoped('/api/file')).then(r => r.text())

export const putFile = (content: string): Promise<unknown> =>
  native ? nativeCall('putFile', { content }) : fetch(scoped('/api/file'), { method: 'PUT', body: content })

export const getFolio = (): Promise<Sidecar> =>
  native ? nativeCall('getFolio') : fetch(scoped('/api/folio')).then(r => r.json())

export const putFolio = (sidecar: Sidecar): Promise<unknown> => {
  // Serialized here so the bytes on disk are identical whichever side writes them.
  const body = JSON.stringify(sidecar, null, 2)
  return native
    ? nativeCall('putFolio', { body })
    : fetch(scoped('/api/folio'), { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body })
}

export const postAccept = (id: string): Promise<void> =>
  native
    ? nativeCall('accept', { id })
    : fetch(scoped('/api/accept'), {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ id }),
      }).then(r => { if (!r.ok) return r.text().then(msg => { throw new Error(msg) }) })

export const getKrokiUrl = (): Promise<string> =>
  native ? call('krokiUrl') : fetch('/api/kroki-url').then(r => r.json()).then(d => d.url)

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

// `text` is the preview's rendered text; the offsets come back as indices into it.
export const postAnchor = (text: string, items: AnchorRequestItem[]): Promise<AnchorResultItem[]> =>
  native
    ? nativeCall('anchor', { text, items })
    : fetch(scoped('/api/anchor'), {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ text, items }),
      }).then(r => r.json())

export const postAnchorRaw = (items: AnchorRequestItem[]): Promise<AnchorResultItem[]> =>
  native
    ? nativeCall('anchorRaw', { items })
    : fetch(scoped('/api/anchor-raw'), {
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
