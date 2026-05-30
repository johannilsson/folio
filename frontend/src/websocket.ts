type EventType = 'md:changed' | 'folio:changed'
type Handler = () => void

const handlers: Map<EventType, Set<Handler>> = new Map()

export function on(event: EventType, handler: Handler): void {
  if (!handlers.has(event)) handlers.set(event, new Set())
  handlers.get(event)!.add(handler)
}

export function off(event: EventType, handler: Handler): void {
  handlers.get(event)?.delete(handler)
}

function dispatch(event: EventType): void {
  handlers.get(event)?.forEach(h => h())
}

function connect(): void {
  const proto = location.protocol === 'https:' ? 'wss:' : 'ws:'
  const ws = new WebSocket(`${proto}//${location.host}/ws`)

  ws.onmessage = (e) => {
    try {
      const msg = JSON.parse(e.data as string)
      if (msg.type === 'md:changed' || msg.type === 'folio:changed') {
        dispatch(msg.type)
      }
    } catch {
      // ignore malformed messages
    }
  }

  ws.onclose = () => {
    setTimeout(connect, 2000)
  }
}

connect()
