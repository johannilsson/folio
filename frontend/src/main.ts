import { on } from './websocket'
import { getFile, getFolio, getInfo } from './api'
import { initEditor, setContent, getEditor } from './editor'
import { createAnnotationsExtension, updateSidecar, scheduleGutterRebuild } from './annotations'

async function boot(): Promise<void> {
  const [initialContent, sidecar, info] = await Promise.all([getFile(), getFolio(), getInfo()])

  const filenameEl = document.getElementById('filename-display')!
  filenameEl.textContent = info.filename
  document.title = info.filename

  updateSidecar(sidecar)

  const editorEl = document.getElementById('editor-tiptap')!
  initEditor(editorEl, initialContent, [createAnnotationsExtension()])

  on('md:changed', async () => {
    const content = await getFile()
    setContent(content)
  })

  on('folio:changed', async () => {
    const updated = await getFolio()
    updateSidecar(updated)
    const ed = getEditor()
    if (ed) ed.view.dispatch(ed.state.tr)
  })

  // Toggle between WYSIWYG and raw markdown
  const toggleBtn = document.getElementById('toggle-raw')!
  const editorWrapper = document.getElementById('editor-wrapper')!
  const rawPane = document.getElementById('raw-pane')!
  const rawTextarea = rawPane.querySelector('textarea') as HTMLTextAreaElement

  toggleBtn.addEventListener('click', () => {
    const ed = getEditor()!
    if (rawPane.hidden) {
      rawTextarea.value = ed.getMarkdown()
      editorWrapper.hidden = true
      rawPane.hidden = false
      toggleBtn.textContent = '← WYSIWYG'
    } else {
      ed.commands.setContent(rawTextarea.value, { contentType: 'markdown' })
      editorWrapper.hidden = false
      rawPane.hidden = true
      toggleBtn.textContent = 'Markdown →'
      scheduleGutterRebuild()
    }
  })
}

boot().catch(console.error)
