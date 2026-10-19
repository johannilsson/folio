import { on } from './websocket'
import { runPendingFlash } from './feedback'
import { initLayoutReporting } from './layout'
import { getFile, getFolio, getInfo, setActiveFile } from './api'
import { initEditor, destroyEditor, setContent, isLocked, getEditor, flushSave } from './editor'
import { createAnnotationsExtension, updateSidecar, resetAnnotationState, triggerSidecarUpdate, triggerContentReplaced, scheduleAnchorReport } from './annotations'
import { createTableUIExtension } from './table-ui'
import { setPlantumlUrl, setMermaidTheme } from './diagrams'

// This page is the rendered preview. The app around it owns everything else: the source editor,
// the toolbar, the comments pane and the toggles (see macos/BRIDGE.md).
async function boot(): Promise<void> {
  const [initialContent, sidecar, info] = await Promise.all([getFile(), getFolio(), getInfo()])

  // The document of the set this page currently shows.
  let currentId = info.id

  function showFilename(filename: string) {
    document.title = filename
  }
  showFilename(info.filename)
  setPlantumlUrl(info.plantumlUrl)

  updateSidecar(sidecar)

  const editorEl = document.getElementById('editor-tiptap')!
  const readOnlyNotice = document.getElementById('preview-readonly-notice')!
  function mountPreview(content: string) {
    initEditor(editorEl, content, [createAnnotationsExtension(), createTableUIExtension()], reason => {
      readOnlyNotice.hidden = reason === null
      readOnlyNotice.title = reason ?? ''
    })
  }
  mountPreview(initialContent)

  // Read the file again into the preview, and anchor the annotations in the new text.
  async function reloadContent(): Promise<void> {
    const content = await getFile()
    setContent(content)
    // Reloading into the existing editor can fail to map back to the source where a
    // fresh editor succeeds (it left the preview read-only after a git pull); rebuild.
    if (isLocked()) {
      destroyEditor()
      mountPreview(content)
    }
    const ed = getEditor()
    if (ed) triggerContentReplaced(ed)
    scheduleAnchorReport()
  }

  // Handle events one at a time: an accept broadcasts md:changed then folio:changed,
  // and re-anchoring must run against the already-reloaded document.
  let eventChain: Promise<void> = Promise.resolve()
  // Events for other files of the set are not ours to apply.
  const sequential = (handler: () => Promise<void>) => (file: string | undefined) => {
    if (file !== undefined && file !== currentId) return
    eventChain = eventChain.then(handler).catch(console.error)
  }

  on('md:changed', sequential(async () => {
    await reloadContent()
    runPendingFlash()
  }))

  on('folio:changed', sequential(async () => {
    const updated = await getFolio()
    const isEcho = updateSidecar(updated)
    const ed = getEditor()
    if (ed) {
      if (isEcho) {
        // Nothing changed in the sidecar; positions are already tracked via tr.mapping.
        ed.view.dispatch(ed.state.tr)
      } else {
        // Genuine update (an agent's, or the app's own action): re-anchor from scratch.
        triggerSidecarUpdate(ed)
      }
    }
  }))

  // Follow OS color scheme for mermaid diagrams
  const colorScheme = window.matchMedia('(prefers-color-scheme: light)')
  setMermaidTheme(colorScheme.matches ? 'default' : 'dark')
  colorScheme.addEventListener('change', e => setMermaidTheme(e.matches ? 'default' : 'dark'))

  // Swap the document in place. The preview editor is built again rather than reused, so its
  // undo history can never reach into the previous file.
  let switching = false
  async function switchFile(id: string): Promise<void> {
    if (id === currentId || switching) return
    switching = true
    const previous = currentId
    try {
      // Save the file we are leaving; pending edits would otherwise be lost.
      await flushSave()
      setActiveFile(id)
      let loaded
      try {
        loaded = await Promise.all([getFile(), getFolio(), getInfo()])
      } catch (e) {
        setActiveFile(previous)
        throw e
      }
      const [content, nextSidecar, nextInfo] = loaded

      currentId = id
      destroyEditor()
      resetAnnotationState()
      updateSidecar(nextSidecar)
      mountPreview(content)
      showFilename(nextInfo.filename)
      scheduleAnchorReport()
    } finally {
      switching = false
    }
  }

  // The app calls these: the window's sidebar picks the file, and coming back from the source
  // the page reads the file the source may have changed.
  const app = window as unknown as {
    __folioSwitchFile: (id: string) => Promise<void>
    __folioReload: () => Promise<void>
  }
  app.__folioSwitchFile = switchFile
  app.__folioReload = reloadContent

  initLayoutReporting()
}

boot().catch(console.error)
