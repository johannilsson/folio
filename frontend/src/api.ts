import { call } from './bridge'

// Which document of a set this page shows (`?file=<id>` on the page URL). Absent means the
// window's first document, so a single file needs no id.
let fileParam = new URLSearchParams(location.search).get('file')

/** Point every file-scoped call at another document of the set. */
export function setActiveFile(id: string): void {
  fileParam = id
}

// File-scoped ops carry the active document id along.
const fileCall = <T>(op: string, payload: Record<string, unknown> = {}): Promise<T> =>
  call<T>(op, { file: fileParam, ...payload })

export const getInfo = (): Promise<{ id: string; filename: string; set: string | null; plantumlUrl: string }> =>
  fileCall('info')

export const getFile = (): Promise<string> => fileCall('getFile')

export const putFile = (content: string): Promise<unknown> => fileCall('putFile', { content })

export const getFolio = (): Promise<Sidecar> => fileCall('getFolio')

export const putFolio = (sidecar: Sidecar): Promise<unknown> =>
  // Serialized here so the bytes on disk are identical whichever side writes them.
  fileCall('putFolio', { body: JSON.stringify(sidecar, null, 2) })

export const postAccept = (id: string): Promise<void> => fileCall('accept', { id })

export const getKrokiUrl = (): Promise<string> => call('krokiUrl')

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
  fileCall('anchor', { text, items })

export const postAnchorRaw = (items: AnchorRequestItem[]): Promise<AnchorResultItem[]> =>
  fileCall('anchorRaw', { items })

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
