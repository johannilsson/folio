import { on } from './websocket'
import { getFile, getFolio, getInfo } from './api'
import { initEditor, setContent, getEditor, getMarkdown } from './editor'
import { createAnnotationsExtension, updateSidecar, triggerSidecarUpdate, triggerContentReplaced, scheduleGutterRebuild } from './annotations'
import { createTableUIExtension } from './table-ui'
import { setPlantumlUrl, setMermaidTheme } from './diagrams'

async function boot(): Promise<void> {
  const [initialContent, sidecar, info] = await Promise.all([getFile(), getFolio(), getInfo()])

  const filenameEl = document.getElementById('filename-display')!
  filenameEl.textContent = info.filename
  document.title = info.filename
  setPlantumlUrl(info.plantumlUrl)

  updateSidecar(sidecar)

  const editorEl = document.getElementById('editor-tiptap')!
  initEditor(editorEl, initialContent, [createAnnotationsExtension(), createTableUIExtension()])

  on('md:changed', async () => {
    const content = await getFile()
    setContent(content)
  })

  on('folio:changed', async () => {
    const updated = await getFolio()
    const isEcho = updateSidecar(updated)
    const ed = getEditor()
    if (!ed) return
    if (isEcho) {
      // Our own PUT echoed back — positions already tracked via tr.mapping; just rebuild gutter.
      ed.view.dispatch(ed.state.tr)
    } else {
      // Genuine external update (new agent annotations) — re-anchor from scratch.
      triggerSidecarUpdate(ed)
    }
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
  const rawTextarea = rawPane.querySelector('textarea') as HTMLTextAreaElement

  function positionThumb(activeBtn: HTMLButtonElement, animate = true) {
    if (!animate) thumb.style.transition = 'none'
    thumb.style.width = activeBtn.offsetWidth + 'px'
    thumb.style.transform = `translateX(${activeBtn === sourceBtn ? previewBtn.offsetWidth : 0}px)`
    if (!animate) requestAnimationFrame(() => { thumb.style.transition = '' })
    previewBtn.classList.toggle('active', activeBtn === previewBtn)
    sourceBtn.classList.toggle('active', activeBtn === sourceBtn)
  }

  requestAnimationFrame(() => positionThumb(previewBtn, false))

  previewBtn.addEventListener('click', () => {
    if (!rawPane.hidden) {
      const fraction = rawTextarea.scrollTop / (rawTextarea.scrollHeight - rawTextarea.clientHeight || 1)
      const ed = getEditor()!
      ed.commands.setContent(rawTextarea.value, { contentType: 'markdown' })
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
      rawTextarea.value = getMarkdown()
      editorWrapper.hidden = true
      rawPane.hidden = false
      rawTextarea.scrollTop = fraction * (rawTextarea.scrollHeight - rawTextarea.clientHeight)
    }
    positionThumb(sourceBtn)
  })
}

boot().catch(console.error)
