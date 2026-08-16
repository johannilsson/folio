import { describe, expect, test } from 'vitest'
import { EditorState, StateEffect } from '@codemirror/state'
import type { Transaction } from '@codemirror/state'
import { history, invertedEffects, isolateHistory, undo, redo } from '@codemirror/commands'

// raw-annotations.ts rides sidecar mutations (accept/reject/resolve/comment/reply)
// along with CM6's undo/redo via invertedEffects. That mechanism is documented but
// its exact behavior for effect-only transactions (no document change — the reject/
// resolve/comment-create case) isn't obvious from the types alone, so this exercises
// the actual CM6 history behavior in isolation rather than trusting the docs.

interface Payload {
  before: string
  after: string
}

const actionEffect = StateEffect.define<Payload>()

const inverter = invertedEffects.of(tr =>
  tr.effects
    .filter((e): e is StateEffect<Payload> => e.is(actionEffect))
    .map(e => actionEffect.of({ before: e.value.after, after: e.value.before })),
)

function makeHarness() {
  let state = EditorState.create({ doc: 'hello world', extensions: [history(), inverter] })
  const dispatched: Transaction[] = []
  const view = {
    get state() {
      return state
    },
    dispatch(tr: Transaction) {
      dispatched.push(tr)
      state = tr.state
    },
  }
  return { view, dispatched }
}

describe('CM6 invertedEffects mechanism (used by raw-annotations.ts)', () => {
  test('a transaction with a document change carries the action effect through undo, inverted', () => {
    const { view, dispatched } = makeHarness()

    view.dispatch(
      view.state.update({
        changes: { from: 0, to: 5, insert: 'goodbye' },
        effects: [actionEffect.of({ before: 'pending', after: 'accepted' })],
        annotations: isolateHistory.of('full'),
      }),
    )
    expect(view.state.doc.toString()).toBe('goodbye world')

    const undone = undo(view)
    expect(undone).toBe(true)
    expect(view.state.doc.toString()).toBe('hello world')

    const undoTr = dispatched[dispatched.length - 1]
    const effects = undoTr.effects.filter((e): e is StateEffect<Payload> => e.is(actionEffect))
    expect(effects).toHaveLength(1)
    expect(effects[0].value).toEqual({ before: 'accepted', after: 'pending' })

    const redone = redo(view)
    expect(redone).toBe(true)
    expect(view.state.doc.toString()).toBe('goodbye world')
    const redoTr = dispatched[dispatched.length - 1]
    const redoEffects = redoTr.effects.filter((e): e is StateEffect<Payload> => e.is(actionEffect))
    expect(redoEffects[0].value).toEqual({ before: 'pending', after: 'accepted' })
  })

  test('an effect-only transaction with NO document change is still recorded and undoable (the reject/resolve/comment case)', () => {
    const { view, dispatched } = makeHarness()
    const before = view.state.doc.toString()

    view.dispatch(
      view.state.update({
        effects: [actionEffect.of({ before: 'pending', after: 'rejected' })],
        annotations: isolateHistory.of('full'),
      }),
    )
    // No text change at all.
    expect(view.state.doc.toString()).toBe(before)

    const undone = undo(view)
    expect(undone).toBe(true) // the critical assertion: an effect-only tx is not silently dropped from history

    const undoTr = dispatched[dispatched.length - 1]
    const effects = undoTr.effects.filter((e): e is StateEffect<Payload> => e.is(actionEffect))
    expect(effects).toHaveLength(1)
    expect(effects[0].value).toEqual({ before: 'rejected', after: 'pending' })
  })

  test('isolateHistory keeps two consecutive actions as separate undo steps', () => {
    const { view } = makeHarness()

    view.dispatch(
      view.state.update({
        effects: [actionEffect.of({ before: 'pending', after: 'rejected' })],
        annotations: isolateHistory.of('full'),
      }),
    )
    view.dispatch(
      view.state.update({
        changes: { from: 0, to: 0, insert: 'X' },
        effects: [actionEffect.of({ before: 'pending2', after: 'accepted2' })],
        annotations: isolateHistory.of('full'),
      }),
    )
    expect(view.state.doc.toString()).toBe('Xhello world')

    undo(view) // should only revert the second action
    expect(view.state.doc.toString()).toBe('hello world')

    undo(view) // second Ctrl+Z reverts the first (effect-only) action
    // still no text change from the first action, but it must exist as its own step
    expect(view.state.doc.toString()).toBe('hello world')
  })
})
