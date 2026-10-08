import { on } from './websocket'
import { getFile, getFolio, getInfo } from './api'
import { initEditor, setContent, getEditor, flushSave } from './editor'
import { createAnnotationsExtension, updateSidecar, triggerSidecarUpdate, triggerContentReplaced, scheduleGutterRebuild } from './annotations'
import { createTableUIExtension } from './table-ui'
import { setPlantumlUrl, setMermaidTheme } from './diagrams'
import { initRawEditor, setRawContent, getRawContent, flushRawSave, refreshRawAnnotations, getRawWrapperEl } from './raw-editor'

async function boot(): Promise<void> {
  const [initialContent, sidecar, info] = await Promise.all([getFile(), getFolio(), getInfo()])

  const filenameEl = document.getElementById('filename-display')!
  filenameEl.textContent = info.filename
  document.title = info.filename
  setPlantumlUrl(info.plantumlUrl)

  updateSidecar(sidecar)

  const editorEl = document.getElementById('editor-tiptap')!
  const readOnlyNotice = document.getElementById('preview-readonly-notice')!
  initEditor(editorEl, initialContent, [createAnnotationsExtension(), createTableUIExtension()], reason => {
    readOnlyNotice.hidden = reason === null
    readOnlyNotice.title = reason ?? ''
  })

  // Handle events one at a time: an accept broadcasts md:changed then folio:changed,
  // and re-anchoring must run against the already-reloaded document.
  let eventChain: Promise<void> = Promise.resolve()
  const sequential = (handler: () => Promise<void>) => () => {
    eventChain = eventChain.then(handler).catch(console.error)
  }

  on('md:changed', sequential(async () => {
    const content = await getFile()
    setContent(content)
    const ed = getEditor()
    if (ed) triggerContentReplaced(ed)
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

  // Highlighted while the markdown source is showing.
  function updateViewBtn() {
    const inSource = !rawPane.hidden
    viewBtn.classList.toggle('active', inSource)
    viewBtn.setAttribute('aria-pressed', String(inSource))
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
      })
    }
    updateViewBtn()
  }

  viewBtn.addEventListener('click', () => (rawPane.hidden ? showSource() : showPreview()))

  // Comments pane: closed by default, toggled with the bubble button
  const appEl = document.getElementById('app')!
  const gutterToggleBtn = document.getElementById('toggle-gutter-btn') as HTMLButtonElement
  function setGutterOpen(open: boolean) {
    appEl.classList.toggle('gutter-open', open)
    gutterToggleBtn.classList.toggle('active', open)
    gutterToggleBtn.setAttribute('aria-pressed', String(open))
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
}

boot().catch(console.error)
