import { on } from './websocket'
import { runPendingFlash } from './feedback'
import { call } from './bridge'
import { getFile, getFolio, getInfo, setActiveFile } from './api'
import { initEditor, destroyEditor, setContent, isLocked, getEditor, flushSave } from './editor'
import { createAnnotationsExtension, updateSidecar, resetAnnotationState, triggerSidecarUpdate, triggerContentReplaced, scheduleGutterRebuild, getSidecar, onSidecarUpdate } from './annotations'
import { createTableUIExtension } from './table-ui'
import { setPlantumlUrl, setMermaidTheme } from './diagrams'
import { initRawEditor, resetRawEditor, setRawContent, getRawContent, flushRawSave, flushPendingRawSave, refreshRawAnnotations, getRawWrapperEl } from './raw-editor'

async function boot(): Promise<void> {
  const [initialContent, sidecar, info] = await Promise.all([getFile(), getFolio(), getInfo()])

  // The document of the served set this page currently shows.
  let currentId = info.id

  function showFilename(filename: string) {
    document.getElementById('filename-display')!.textContent = filename
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

  // Handle events one at a time: an accept broadcasts md:changed then folio:changed,
  // and re-anchoring must run against the already-reloaded document.
  let eventChain: Promise<void> = Promise.resolve()
  // Events for other files of the set are not ours to apply.
  const sequential = (handler: () => Promise<void>) => (file: string | undefined) => {
    if (file !== undefined && file !== currentId) return
    eventChain = eventChain.then(handler).catch(console.error)
  }

  on('md:changed', sequential(async () => {
    const content = await getFile()
    setContent(content)
    // Reloading into the existing editor can fail to map back to the source where a
    // fresh editor succeeds (it left the preview read-only after a git pull); rebuild.
    if (isLocked()) {
      destroyEditor()
      mountPreview(content)
      scheduleGutterRebuild()
    }
    const ed = getEditor()
    if (ed) triggerContentReplaced(ed)
    runPendingFlash()
    if (!rawPane.hidden) {
      setRawContent(content)
      refreshRawAnnotations()
    }
  }))

  on('folio:changed', sequential(async () => {
    const updated = await getFolio()
    const isEcho = updateSidecar(updated)
    const ed = getEditor()
    if (ed) {
      if (isEcho) {
        // Our own PUT echoed back — positions already tracked via tr.mapping; just rebuild gutter.
        ed.view.dispatch(ed.state.tr)
      } else {
        // Genuine external update (new agent annotations) — re-anchor from scratch.
        triggerSidecarUpdate(ed)
      }
    }
    if (!rawPane.hidden && !isEcho) refreshRawAnnotations()
  }))

  // Follow OS color scheme for mermaid diagrams
  const colorScheme = window.matchMedia('(prefers-color-scheme: light)')
  setMermaidTheme(colorScheme.matches ? 'default' : 'dark')
  colorScheme.addEventListener('change', e => setMermaidTheme(e.matches ? 'default' : 'dark'))

  // Single button toggles between WYSIWYG preview and raw markdown source
  const viewBtn = document.getElementById('view-toggle-btn') as HTMLButtonElement
  const editorWrapper = document.getElementById('editor-wrapper')!
  const rawPane = document.getElementById('raw-pane')!

  // The native app's toolbar mirrors the source and comments toggles.
  function reportUiState() {
    const comments = document.getElementById('app')!.classList.contains('gutter-open')
    const pending = getSidecar().annotations.filter(a => !a.resolved).length
    void call('uiState', { source: !rawPane.hidden, comments, pending }).catch(console.error)
  }
  onSidecarUpdate(reportUiState)

  // Highlighted while the markdown source is showing.
  function updateViewBtn() {
    const inSource = !rawPane.hidden
    viewBtn.classList.toggle('active', inSource)
    viewBtn.setAttribute('aria-pressed', String(inSource))
    reportUiState()
  }

  // Default to source/raw mode — CM6 edits the file directly with no
  // reformat-on-save round trip, so it's the primary editing surface now.
  initRawEditor(rawPane, initialContent)
  refreshRawAnnotations()
  updateViewBtn()

  function showPreview() {
    if (!rawPane.hidden) {
      const wrapperEl = getRawWrapperEl()
      const fraction = wrapperEl ? wrapperEl.scrollTop / (wrapperEl.scrollHeight - wrapperEl.clientHeight || 1) : 0
      flushRawSave()
      const ed = getEditor()!
      // Switching to preview is a pure render step, never a save trigger.
      setContent(getRawContent())
      editorWrapper.hidden = false
      rawPane.hidden = true
      triggerContentReplaced(ed)
      scheduleGutterRebuild()
      requestAnimationFrame(() => requestAnimationFrame(() => {
        editorWrapper.scrollTop = fraction * (editorWrapper.scrollHeight - editorWrapper.clientHeight)
      }))
    }
    updateViewBtn()
  }

  function showSource() {
    if (rawPane.hidden) {
      const fraction = editorWrapper.scrollTop / (editorWrapper.scrollHeight - editorWrapper.clientHeight || 1)
      flushSave().then(getFile).then(content => {
        initRawEditor(rawPane, content)
        setRawContent(content)
        editorWrapper.hidden = true
        rawPane.hidden = false
        refreshRawAnnotations()
        const wrapperEl = getRawWrapperEl()
        if (wrapperEl) wrapperEl.scrollTop = fraction * (wrapperEl.scrollHeight - wrapperEl.clientHeight)
        // Only now is the source showing; updating earlier left the toggle showing preview.
        updateViewBtn()
      })
      return
    }
    updateViewBtn()
  }

  viewBtn.addEventListener('click', () => (rawPane.hidden ? showSource() : showPreview()))

  // The app opens in the WYSIWYG preview.
  showPreview()

  // Comments pane: closed by default, toggled with the bubble button
  const appEl = document.getElementById('app')!
  const gutterToggleBtn = document.getElementById('toggle-gutter-btn') as HTMLButtonElement
  function setGutterOpen(open: boolean) {
    appEl.classList.toggle('gutter-open', open)
    gutterToggleBtn.classList.toggle('active', open)
    gutterToggleBtn.setAttribute('aria-pressed', String(open))
    reportUiState()
    window.dispatchEvent(new Event('folio:gutter-toggled'))
    if (open) {
      // Cards were laid out while display:none (zero heights) — rebuild now.
      scheduleGutterRebuild()
      refreshRawAnnotations()
    }
  }
  gutterToggleBtn.addEventListener('click', () => setGutterOpen(!appEl.classList.contains('gutter-open')))
  window.addEventListener('folio:open-gutter', () => {
    if (!appEl.classList.contains('gutter-open')) setGutterOpen(true)
  })

  // Swap the document in place. Both editors are reset rather than reused: a
  // fresh preview editor and a fresh CM6 state each start with empty undo
  // history, so undo can never reach into the previous file.
  let switching = false
  // Scroll position of each file we have left, as a fraction of its scrollable
  // height (the same measure the source/preview toggle uses), so coming back
  // lands where the reader left off. Kept for this page session only.
  const scrollFractions = new Map<string, number>()
  const visibleWrapper = () => (rawPane.hidden ? editorWrapper : getRawWrapperEl())
  async function switchFile(id: string): Promise<void> {
    if (id === currentId || switching) return
    switching = true
    const previous = currentId
    const leaving = visibleWrapper()
    if (leaving) scrollFractions.set(previous, leaving.scrollTop / (leaving.scrollHeight - leaving.clientHeight || 1))
    try {
      // Save the file we are leaving; pending edits would otherwise be lost.
      await (rawPane.hidden ? flushSave() : flushPendingRawSave())
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
      resetRawEditor(content)
      editorWrapper.scrollTop = 0
      // Wait for layout so the new document has its height before we scroll into it.
      const fraction = scrollFractions.get(id) ?? 0
      requestAnimationFrame(() => requestAnimationFrame(() => {
        const el = visibleWrapper()
        if (el && currentId === id) el.scrollTop = fraction * (el.scrollHeight - el.clientHeight)
      }))
      showFilename(nextInfo.filename)
      if (!rawPane.hidden) refreshRawAnnotations()
      scheduleGutterRebuild()
    } finally {
      switching = false
    }
  }

  // The window's sidebar picks the file; there is no in-page menu to do it.
  ;(window as unknown as { __folioSwitchFile: (id: string) => Promise<void> }).__folioSwitchFile = switchFile
}

boot().catch(console.error)
