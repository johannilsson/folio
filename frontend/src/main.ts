import { on } from './websocket'
import { getFile, getFolio, getKrokiUrl } from './api'
import { initEditor, setContent, onChange, getView } from './editor'
import { initPreview, renderPreview } from './preview'
import { annotationPlugin, updateSidecar } from './annotations'

async function boot(): Promise<void> {
  const [initialContent, sidecar, krokiUrl] = await Promise.all([
    getFile(),
    getFolio(),
    getKrokiUrl(),
  ])

  // Set sidecar before editor initialises so the plugin renders on first paint
  updateSidecar(sidecar)

  const previewEl = document.getElementById('preview')!
  initPreview(previewEl, krokiUrl)
  renderPreview(initialContent)

  const editorPane = document.getElementById('editor-pane')!
  initEditor(editorPane, initialContent, [annotationPlugin])

  onChange(content => renderPreview(content))

  on('md:changed', async () => {
    const content = await getFile()
    setContent(content)
    renderPreview(content)
  })

  on('folio:changed', async () => {
    const updated = await getFolio()
    updateSidecar(updated)
    getView()?.dispatch({})
  })
}

boot().catch(console.error)
