// The page runs inside the macOS app's WKWebView and talks to Swift through a script
// message handler. See macos/BRIDGE.md for the ops.
interface NativeHandler {
  postMessage(message: unknown): Promise<unknown>
}

const handler = (window as unknown as {
  webkit?: { messageHandlers?: { folio?: NativeHandler } }
}).webkit?.messageHandlers?.folio

/** Ask Swift to do `op`. A failure on the native side rejects the promise. */
export function call<T>(op: string, payload: Record<string, unknown> = {}): Promise<T> {
  if (!handler) return Promise.reject(new Error('Folio runs inside its macOS app: no native bridge found'))
  return handler.postMessage({ op, ...payload }) as Promise<T>
}
