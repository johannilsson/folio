// In the native macOS app the page runs inside a WKWebView and talks to Swift through
// a script message handler instead of HTTP. Elsewhere (browser, CLI server) this is
// absent and api.ts / websocket.ts use fetch and WebSocket as before.
// See macos/BRIDGE.md for the ops.
interface NativeHandler {
  postMessage(message: unknown): Promise<unknown>
}

const handler = (window as unknown as {
  webkit?: { messageHandlers?: { folio?: NativeHandler } }
}).webkit?.messageHandlers?.folio

export const native = handler !== undefined

/** Ask Swift to do `op`. A failure on the native side rejects the promise. */
export function call<T>(op: string, payload: Record<string, unknown> = {}): Promise<T> {
  return handler!.postMessage({ op, ...payload }) as Promise<T>
}
