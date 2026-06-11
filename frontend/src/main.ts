import { on } from './websocket'
import { getFile, getFolio, getInfo } from './api'
import { initEditor, setContent, getEditor, getMarkdown } from './editor'
import { createAnnotationsExtension, updateSidecar, scheduleGutterRebuild } from './annotations'
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
    updateSidecar(updated)
    const ed = getEditor()
    if (ed) ed.view.dispatch(ed.state.tr)
  })

  // Theme toggle
  const themeBtn = document.getElementById('toggle-theme')!

  function isLight(): boolean {
    const saved = document.documentElement.dataset.theme
    if (saved === 'light') return true
    if (saved === 'dark') return false
    return window.matchMedia('(prefers-color-scheme: light)').matches
  }

  function applyTheme(light: boolean) {
    document.documentElement.dataset.theme = light ? 'light' : 'dark'
    localStorage.setItem('folio-theme', light ? 'light' : 'dark')
    themeBtn.textContent = light ? '◑' : '☀'
    setMermaidTheme(light ? 'default' : 'dark')
  }

  applyTheme(isLight())

  themeBtn.addEventListener('click', () => applyTheme(!isLight()))

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
      const ed = getEditor()!
      ed.commands.setContent(rawTextarea.value, { contentType: 'markdown' })
      editorWrapper.hidden = false
      rawPane.hidden = true
      scheduleGutterRebuild()
    }
    positionThumb(previewBtn)
  })

  sourceBtn.addEventListener('click', () => {
    if (rawPane.hidden) {
      rawTextarea.value = getMarkdown()
      editorWrapper.hidden = true
      rawPane.hidden = false
    }
    positionThumb(sourceBtn)
  })
}

boot().catch(console.error)
