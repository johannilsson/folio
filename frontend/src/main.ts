import { on } from './websocket'
import { getFile, getFolio, getInfo } from './api'
import { initEditor, setContent, getEditor } from './editor'
import { createAnnotationsExtension, updateSidecar, triggerSidecarUpdate, triggerContentReplaced, scheduleGutterRebuild, setGutterHidden } from './annotations'
import { setPlantumlUrl, setMermaidTheme } from './diagrams'
import { initRawEditor, setRawContent, getRawContent, flushRawSave, refreshRawAnnotations, getRawWrapperEl, setRawGutterHidden } from './raw-editor'

async function boot(): Promise<void> {
  const [initialContent, sidecar, info] = await Promise.all([getFile(), getFolio(), getInfo()])

  const filenameEl = document.getElementById('filename-display')!
  filenameEl.textContent = info.filename
  document.title = info.filename
  setPlantumlUrl(info.plantumlUrl)

  updateSidecar(sidecar)

  const editorEl = document.getElementById('editor-tiptap')!
  initEditor(editorEl, initialContent, [createAnnotationsExtension()])

  on('md:changed', async () => {
    const content = await getFile()
    setContent(content)
    if (!rawPane.hidden) {
      setRawContent(content)
      refreshRawAnnotations()
    }
  })

  on('folio:changed', async () => {
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
  })

  // Follow OS color scheme for mermaid diagrams
  const colorScheme = window.matchMedia('(prefers-color-scheme: light)')
  setMermaidTheme(colorScheme.matches ? 'default' : 'dark')
  colorScheme.addEventListener('change', e => setMermaidTheme(e.matches ? 'default' : 'dark'))

  // Toggle between WYSIWYG and raw markdown
  const thumb = document.getElementById('view-toggle-thumb') as HTMLElement
  const previewBtn = document.getElementById('view-toggle-preview') as HTMLButtonElement
  const sourceBtn = document.getElementById('view-toggle-source') as HTMLButtonElement
  const editorWrapper = document.getElementById('editor-wrapper')!
  const rawPane = document.getElementById('raw-pane')!

  function positionThumb(activeBtn: HTMLButtonElement, animate = true) {
    if (!animate) thumb.style.transition = 'none'
    thumb.style.width = activeBtn.offsetWidth + 'px'
    thumb.style.transform = `translateX(${activeBtn === sourceBtn ? previewBtn.offsetWidth : 0}px)`
    if (!animate) requestAnimationFrame(() => { thumb.style.transition = '' })
    previewBtn.classList.toggle('active', activeBtn === previewBtn)
    sourceBtn.classList.toggle('active', activeBtn === sourceBtn)
  }

  // Default to source/raw mode — CM6 edits the file directly with no
  // reformat-on-save round trip, so it's the primary editing surface now.
  initRawEditor(rawPane, initialContent)
  refreshRawAnnotations()
  requestAnimationFrame(() => positionThumb(sourceBtn, false))

  previewBtn.addEventListener('click', () => {
    if (!rawPane.hidden) {
      const wrapperEl = getRawWrapperEl()
      const fraction = wrapperEl ? wrapperEl.scrollTop / (wrapperEl.scrollHeight - wrapperEl.clientHeight || 1) : 0
      flushRawSave()
      const ed = getEditor()!
      // emitUpdate: false — switching to preview must be a pure render step,
      // never a save trigger (Tiptap's onUpdate would otherwise re-serialize
      // and reformat the whole file the moment you switch back).
      ed.commands.setContent(getRawContent(), { contentType: 'markdown', emitUpdate: false })
      editorWrapper.hidden = false
      rawPane.hidden = true
      triggerContentReplaced(ed)
      scheduleGutterRebuild()
      requestAnimationFrame(() => requestAnimationFrame(() => {
        editorWrapper.scrollTop = fraction * (editorWrapper.scrollHeight - editorWrapper.clientHeight)
      }))
    }
    positionThumb(previewBtn)
  })

  sourceBtn.addEventListener('click', () => {
    if (rawPane.hidden) {
      const fraction = editorWrapper.scrollTop / (editorWrapper.scrollHeight - editorWrapper.clientHeight || 1)
      getFile().then(content => {
        initRawEditor(rawPane, content)
        setRawContent(content)
        editorWrapper.hidden = true
        rawPane.hidden = false
        refreshRawAnnotations()
        const wrapperEl = getRawWrapperEl()
        if (wrapperEl) wrapperEl.scrollTop = fraction * (wrapperEl.scrollHeight - wrapperEl.clientHeight)
      })
    }
    positionThumb(sourceBtn)
  })

  // Toggle the annotation gutter/pane, independent of which editor is active
  const gutterToggleBtn = document.getElementById('toggle-gutter-btn') as HTMLButtonElement
  let gutterVisible = true
  gutterToggleBtn.addEventListener('click', () => {
    gutterVisible = !gutterVisible
    setGutterHidden(!gutterVisible)
    setRawGutterHidden(!gutterVisible)
    gutterToggleBtn.classList.toggle('active', gutterVisible)
    gutterToggleBtn.setAttribute('aria-pressed', String(gutterVisible))
  })
}

boot().catch(console.error)
