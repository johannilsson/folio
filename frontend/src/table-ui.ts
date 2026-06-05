import { Extension } from '@tiptap/core'
import { Plugin, PluginKey } from '@tiptap/pm/state'
import { TextSelection } from '@tiptap/pm/state'
import type { EditorView } from '@tiptap/pm/view'
import { isInTable, moveTableRow, moveTableColumn } from '@tiptap/pm/tables'

const tableUIKey = new PluginKey('tableUI')

// ── Utilities ────────────────────────────────────────────────────────────────

function getCellColIndex(cell: HTMLTableCellElement): number {
  let col = 0
  for (const c of Array.from((cell.parentElement as HTMLTableRowElement).cells)) {
    if (c === cell) return col
    col += c.colSpan
  }
  return 0
}

function getTableRowIndex(row: HTMLTableRowElement): number {
  const table = row.closest('table') as HTMLTableElement
  return Array.from(table.rows).indexOf(row)
}

function getTableColCount(table: HTMLTableElement): number {
  let count = 0
  for (const c of Array.from(table.rows[0]?.cells ?? [])) count += c.colSpan
  return count
}

// ── Extension ────────────────────────────────────────────────────────────────

export function createTableUIExtension(): ReturnType<typeof Extension.create> {
  return Extension.create({
    name: 'tableUI',

    addProseMirrorPlugins() {
      const editor = this.editor

      return [
        new Plugin({
          key: tableUIKey,

          view(pmView: EditorView) {
            const container = document.getElementById('editor-wrapper')!
            const editorDOM = pmView.dom as HTMLElement

            // ── DOM elements ──────────────────────────────────────────────

            const colHandle = document.createElement('button')
            colHandle.id = 'table-col-handle'
            colHandle.hidden = true
            colHandle.setAttribute('aria-label', 'Column options')
            container.appendChild(colHandle)

            const rowHandle = document.createElement('button')
            rowHandle.id = 'table-row-handle'
            rowHandle.hidden = true
            rowHandle.setAttribute('aria-label', 'Row options')
            container.appendChild(rowHandle)

            const colMenu = document.createElement('div')
            colMenu.id = 'table-col-menu'
            colMenu.setAttribute('role', 'menu')
            colMenu.hidden = true
            colMenu.innerHTML = [
              '<button data-action="addColLeft">← Add column left</button>',
              '<button data-action="addColRight">→ Add column right</button>',
              '<div class="tt-menu-sep"></div>',
              '<button data-action="moveColLeft">← Move left</button>',
              '<button data-action="moveColRight">→ Move right</button>',
              '<div class="tt-menu-sep"></div>',
              '<button data-action="deleteCol" class="tt-menu-danger">Delete column</button>',
            ].join('')
            container.appendChild(colMenu)

            const rowMenu = document.createElement('div')
            rowMenu.id = 'table-row-menu'
            rowMenu.setAttribute('role', 'menu')
            rowMenu.hidden = true
            rowMenu.innerHTML = [
              '<button data-action="addRowAbove">↑ Add row above</button>',
              '<button data-action="addRowBelow">↓ Add row below</button>',
              '<div class="tt-menu-sep"></div>',
              '<button data-action="moveRowUp">↑ Move up</button>',
              '<button data-action="moveRowDown">↓ Move down</button>',
              '<div class="tt-menu-sep"></div>',
              '<button data-action="deleteRow" class="tt-menu-danger">Delete row</button>',
            ].join('')
            container.appendChild(rowMenu)

            const addRowBtn = document.createElement('button')
            addRowBtn.id = 'table-extend-row'
            addRowBtn.hidden = true
            addRowBtn.title = 'Add row'
            addRowBtn.textContent = '+'
            container.appendChild(addRowBtn)

            const addColBtn = document.createElement('button')
            addColBtn.id = 'table-extend-col'
            addColBtn.hidden = true
            addColBtn.title = 'Add column'
            addColBtn.textContent = '+'
            container.appendChild(addColBtn)

            // ── State ─────────────────────────────────────────────────────

            let currentView: EditorView = pmView
            let hoveredCell: HTMLTableCellElement | null = null
            let activeColIndex = -1
            let activeRowIndex = -1
            let activeTable: HTMLTableElement | null = null
            let hideTimer: ReturnType<typeof setTimeout> | null = null

            // ── Hide helpers ──────────────────────────────────────────────

            function closeMenus(): void {
              colMenu.hidden = true
              rowMenu.hidden = true
            }

            function scheduleHide(): void {
              if (hideTimer) return
              hideTimer = setTimeout(() => {
                hideTimer = null
                if (!colMenu.hidden || !rowMenu.hidden) return
                colHandle.hidden = true
                rowHandle.hidden = true
                hoveredCell = null
              }, 150)
            }

            function cancelHide(): void {
              if (hideTimer) { clearTimeout(hideTimer); hideTimer = null }
            }

            function hideAll(): void {
              cancelHide()
              colHandle.hidden = true
              rowHandle.hidden = true
              closeMenus()
              hoveredCell = null
            }

            // ── Focus hovered cell in PM ──────────────────────────────────

            function focusHoveredCell(): void {
              if (!hoveredCell) return
              const rect = hoveredCell.getBoundingClientRect()
              const pos = currentView.posAtCoords({
                left: rect.left + rect.width / 2,
                top: rect.top + rect.height / 2,
              })
              if (!pos) return
              try {
                const $pos = currentView.state.doc.resolve(pos.pos)
                currentView.dispatch(
                  currentView.state.tr.setSelection(TextSelection.near($pos)),
                )
              } catch { /* out of range */ }
            }

            // ── Positioning ───────────────────────────────────────────────

            const COL_HANDLE_H = 12
            const ROW_HANDLE_W = 12

            function positionColHandle(cell: HTMLTableCellElement, table: HTMLTableElement): void {
              const cRect = container.getBoundingClientRect()
              const sTop = container.scrollTop
              const cellRect = cell.getBoundingClientRect()
              const tRect = table.getBoundingClientRect()
              colHandle.style.top = `${tRect.top - cRect.top + sTop - COL_HANDLE_H - 2}px`
              colHandle.style.left = `${cellRect.left - cRect.left}px`
              colHandle.style.width = `${cellRect.width}px`
              colHandle.hidden = false
            }

            function positionRowHandle(row: HTMLTableRowElement, table: HTMLTableElement): void {
              const cRect = container.getBoundingClientRect()
              const sTop = container.scrollTop
              const rowRect = row.getBoundingClientRect()
              const tRect = table.getBoundingClientRect()
              rowHandle.style.top = `${rowRect.top - cRect.top + sTop}px`
              rowHandle.style.left = `${tRect.left - cRect.left - ROW_HANDLE_W - 2}px`
              rowHandle.style.height = `${rowRect.height}px`
              rowHandle.hidden = false
            }

            function positionExtendButtons(table: HTMLTableElement): void {
              const cRect = container.getBoundingClientRect()
              const sTop = container.scrollTop
              const tRect = table.getBoundingClientRect()
              addRowBtn.style.top = `${tRect.bottom - cRect.top + sTop + 4}px`
              addRowBtn.style.left = `${tRect.left - cRect.left}px`
              addRowBtn.hidden = false
              addColBtn.style.top = `${tRect.top - cRect.top + sTop}px`
              addColBtn.style.left = `${tRect.right - cRect.left + 4}px`
              addColBtn.hidden = false
            }

            // ── Menu open/close ───────────────────────────────────────────

            function openColMenu(): void {
              if (!activeTable) return
              const colCount = getTableColCount(activeTable)
              const mLeft = colMenu.querySelector<HTMLButtonElement>('[data-action="moveColLeft"]')!
              const mRight = colMenu.querySelector<HTMLButtonElement>('[data-action="moveColRight"]')!
              mLeft.disabled = activeColIndex <= 0
              mRight.disabled = activeColIndex >= colCount - 1

              const cRect = container.getBoundingClientRect()
              const sTop = container.scrollTop
              const hRect = colHandle.getBoundingClientRect()
              colMenu.style.top = `${hRect.bottom - cRect.top + sTop + 2}px`
              colMenu.style.left = `${hRect.left - cRect.left}px`
              colMenu.hidden = false
              rowMenu.hidden = true
            }

            function openRowMenu(): void {
              if (!activeTable) return
              const rowCount = activeTable.rows.length
              const mUp = rowMenu.querySelector<HTMLButtonElement>('[data-action="moveRowUp"]')!
              const mDown = rowMenu.querySelector<HTMLButtonElement>('[data-action="moveRowDown"]')!
              mUp.disabled = activeRowIndex <= 1  // row 0 is the header
              mDown.disabled = activeRowIndex >= rowCount - 1

              const cRect = container.getBoundingClientRect()
              const sTop = container.scrollTop
              const hRect = rowHandle.getBoundingClientRect()
              rowMenu.style.top = `${hRect.top - cRect.top + sTop}px`
              rowMenu.style.left = `${hRect.right - cRect.left + 2}px`
              rowMenu.hidden = false
              colMenu.hidden = true
            }

            // ── Menu actions ──────────────────────────────────────────────

            colMenu.addEventListener('mousedown', (e) => {
              const btn = (e.target as Element).closest('[data-action]') as HTMLElement | null
              if (!btn || (btn as HTMLButtonElement).disabled) return
              e.preventDefault()
              closeMenus()
              switch (btn.dataset.action) {
                case 'addColLeft':   editor.commands.addColumnBefore(); break
                case 'addColRight':  editor.commands.addColumnAfter();  break
                case 'deleteCol':    editor.commands.deleteColumn();     break
                case 'moveColLeft':
                  moveTableColumn({ from: activeColIndex, to: activeColIndex - 1 })(
                    currentView.state, currentView.dispatch,
                  )
                  break
                case 'moveColRight':
                  moveTableColumn({ from: activeColIndex, to: activeColIndex + 1 })(
                    currentView.state, currentView.dispatch,
                  )
                  break
              }
            })

            rowMenu.addEventListener('mousedown', (e) => {
              const btn = (e.target as Element).closest('[data-action]') as HTMLElement | null
              if (!btn || (btn as HTMLButtonElement).disabled) return
              e.preventDefault()
              closeMenus()
              switch (btn.dataset.action) {
                case 'addRowAbove': editor.commands.addRowBefore(); break
                case 'addRowBelow': editor.commands.addRowAfter();  break
                case 'deleteRow':   editor.commands.deleteRow();    break
                case 'moveRowUp':
                  moveTableRow({ from: activeRowIndex, to: activeRowIndex - 1 })(
                    currentView.state, currentView.dispatch,
                  )
                  break
                case 'moveRowDown':
                  moveTableRow({ from: activeRowIndex, to: activeRowIndex + 1 })(
                    currentView.state, currentView.dispatch,
                  )
                  break
              }
            })

            // ── Handle clicks ─────────────────────────────────────────────

            colHandle.addEventListener('mousedown', (e) => {
              e.preventDefault()
              cancelHide()
              focusHoveredCell()
              if (colMenu.hidden) openColMenu(); else closeMenus()
            })

            rowHandle.addEventListener('mousedown', (e) => {
              e.preventDefault()
              cancelHide()
              focusHoveredCell()
              if (rowMenu.hidden) openRowMenu(); else closeMenus()
            })

            // Keep visible when mouse is over handles or menus
            for (const el of [colHandle, rowHandle, colMenu, rowMenu]) {
              el.addEventListener('mouseenter', cancelHide)
              el.addEventListener('mouseleave', scheduleHide)
            }

            // Close menus on outside click
            function onDocMousedown(e: MouseEvent): void {
              const t = e.target as Node
              if (
                !colMenu.contains(t) && !rowMenu.contains(t) &&
                !colHandle.contains(t) && !rowHandle.contains(t)
              ) {
                closeMenus()
              }
            }
            document.addEventListener('mousedown', onDocMousedown)

            // ── Extend buttons ────────────────────────────────────────────

            addRowBtn.addEventListener('mousedown', (e) => {
              e.preventDefault()
              editor.commands.addRowAfter()
            })
            addColBtn.addEventListener('mousedown', (e) => {
              e.preventDefault()
              editor.commands.addColumnAfter()
            })

            // ── Mouse tracking ────────────────────────────────────────────

            function onMouseMove(e: MouseEvent): void {
              const cell = (e.target as Element).closest('td, th') as HTMLTableCellElement | null
              if (!cell) { scheduleHide(); return }
              cancelHide()

              const newCol = getCellColIndex(cell)
              const row = cell.parentElement as HTMLTableRowElement
              const newRow = getTableRowIndex(row)

              if (cell !== hoveredCell) {
                if (newCol !== activeColIndex) colMenu.hidden = true
                if (newRow !== activeRowIndex) rowMenu.hidden = true
              }

              hoveredCell = cell
              activeColIndex = newCol
              activeRowIndex = newRow
              activeTable = cell.closest('table') as HTMLTableElement

              positionColHandle(cell, activeTable)
              positionRowHandle(row, activeTable)
            }

            editorDOM.addEventListener('mousemove', onMouseMove)
            editorDOM.addEventListener('mouseleave', scheduleHide)

            // ── Scroll: reposition open handles ──────────────────────────

            function onScroll(): void {
              if (!hoveredCell || !activeTable) return
              positionColHandle(hoveredCell, activeTable)
              positionRowHandle(hoveredCell.parentElement as HTMLTableRowElement, activeTable)
              if (!colMenu.hidden) openColMenu()
              if (!rowMenu.hidden) openRowMenu()
            }
            container.addEventListener('scroll', onScroll)

            // ── PM state updates: extend buttons only ─────────────────────

            return {
              update(view: EditorView): void {
                currentView = view
                if (!isInTable(view.state)) {
                  addRowBtn.hidden = true
                  addColBtn.hidden = true
                  return
                }
                try {
                  const { $from } = view.state.selection
                  const { node } = view.domAtPos($from.pos)
                  const ref = node instanceof Element ? node : (node as Node).parentElement
                  const table = ref?.closest('table') as HTMLTableElement | null
                  if (table) positionExtendButtons(table)
                  else { addRowBtn.hidden = true; addColBtn.hidden = true }
                } catch {
                  addRowBtn.hidden = true
                  addColBtn.hidden = true
                }
              },

              destroy(): void {
                document.removeEventListener('mousedown', onDocMousedown)
                editorDOM.removeEventListener('mousemove', onMouseMove)
                editorDOM.removeEventListener('mouseleave', scheduleHide)
                container.removeEventListener('scroll', onScroll)
                hideAll()
                for (const el of [colHandle, rowHandle, colMenu, rowMenu, addRowBtn, addColBtn]) {
                  el.remove()
                }
              },
            }
          },
        }),
      ]
    },
  })
}
