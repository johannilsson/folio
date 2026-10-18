type EventType ='md:changed' | 'folio:changed'
// `file` is the id of the document the event is about.
type Handler = (file: string | undefined) => void

const handlers: Map<EventType, Set<Handler>> = new Map()

export function on(event: EventType, handler: Handler): void {
  if (!handlers.has(event)) handlers.set(event, new Set())
  handlers.get(event)!.add(handler)
}

export function off(event: EventType, handler: Handler): void {
  handlers.get(event)?.delete(handler)
}

function dispatch(event: EventType, file: string | undefined): void {
  handlers.get(event)?.forEach(h => h(file))
}

// Swift's file watchers call this when a file or its sidecar changes on disk.
;(window as unknown as { __folioEmit: (type: EventType, file?: string) => void }).__folioEmit =
  (type, file) => dispatch(type, file)
