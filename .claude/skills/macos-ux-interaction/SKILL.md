---
name: macos-ux-interaction
description: >
  Design the interaction and flow of a native macOS SwiftUI app so it feels
  predictable, forgiving, and fast — not just pretty. Use this whenever you are
  adding or changing behavior: buttons that trigger work, destructive or
  irreversible actions, long-running/async tasks, progress, empty/error/loading
  states, keyboard shortcuts and focus, drag-and-drop, selection, undo, sheets,
  confirmations, notifications, or any flow the user moves through. Trigger it
  even when the user just says "this feels clunky", "make it smoother", "improve
  the flow", "handle errors better", or is wiring up a new action. This is the
  interaction/behavior companion to macos-ui-design (which covers visual style).
---

# Interaction & flow for native macOS apps

Good Mac UX is mostly about **respecting the user's control and attention**:
never lose their work, never block them, never surprise them, always tell them
what happened. Visual polish (see `macos-ui-design`) makes an app look right;
interaction design makes it *feel* right. Read this, then apply the parts that
match the behavior you're touching.

## The mental model: keep the user in control

1. **Non-destructive by default; confirm the destructive.** Any action that
   deletes, overwrites, or throws away work needs either an undo or an explicit
   `.confirmationDialog` phrased as the question, with the destructive verb as a
   `role: .destructive` button. Prefer *undo* over *confirm* where feasible —
   confirmations are friction; undo is forgiveness without friction.
2. **Never block the UI.** Long work runs async; the window stays responsive.
   Show progress, keep Cancel available, and let the user keep using unrelated
   parts of the app. A spinner that freezes the window is a bug, not a state.
3. **Every action produces visible feedback within ~100ms.** If the real work
   takes longer, immediately reflect that it *started* (state change, progress,
   disabled button) so the click never feels ignored.
4. **State is honest and specific.** "Processing…" is weak; "Transcribing
   chunk 3/12" tells the user it's alive and roughly how long. Errors say what
   failed and what they can do next, not just "Error".
5. **Idempotent, resumable, restartable.** If a task can fail or be cancelled,
   design so re-running continues from where it left off rather than redoing
   everything. Surface "Resume" not just "Start".

## Async work & progress (the core of this app's UX)

- The moment work starts, flip UI state: disable the trigger or swap it to a
  Cancel/Stop affordance, and show a `ProgressView(value:)` with a specific
  status line. A determinate bar beats a spinner whenever you can estimate
  progress.
- Keep **Cancel** reachable the whole time, and make cancellation *safe* —
  cancelling should leave saved partial results intact, not corrupt state.
- On completion, change state visibly (checkmark, "Done", updated counts) and,
  if the result is a file/output, offer the next step ("Reveal in Finder",
  "Export"). Don't leave the user guessing whether it worked.
- On failure, keep what succeeded, set an actionable error, and offer retry
  from the failure point. Distinguish "you can retry" from "this can't work
  here" (e.g., a missing capability) — the wording changes what the user does.
- For repeated/parallel work, give each unit stable identity so progress and
  retries target the right item and don't double-apply.

## Buttons, actions, and reversibility

- Match the affordance to the consequence: a primary action is prominent; a
  destructive one is red and confirmed/undoable; a repeated inline action is
  quiet (borderless) and, if risky, guarded by `canX` guards so it disables
  when unavailable rather than failing on click.
- Disable, don't hide, actions that are temporarily unavailable — hiding makes
  the UI feel unstable. Pair a disabled control with a `.help` explaining why.
- Mirror the same action in the places users expect it: a row's context menu
  (`.contextMenu`), a visible trailing button for discoverability, and a menu
  bar command with a shortcut. Same verb, same icon, everywhere.

## Keyboard, focus, and menus

- Everything frequent should be keyboard-reachable. Put real commands in the
  menu bar with `.keyboardShortcut`, and let users remap if the app offers it.
- Sheets and dialogs honor Return (`.defaultAction`) and Escape
  (`.cancelAction`). Give text fields sensible default focus.
- Respect standard shortcuts (⌘Z undo, ⌘, settings, ⌘W close, space to
  play/pause in a player). Don't override system meanings.

## Empty, loading, and first-run states

- Design the empty state as a helpful starting point, not a void:
  `ContentUnavailableView` with one inviting sentence and, ideally, the primary
  action right there ("Open a video…").
- Distinguish *empty* (nothing yet — invite action) from *loading* (working —
  show progress) from *error* (something broke — explain + retry). Three
  different states, three different treatments.

## Sheets, confirmations, notifications

- Use a sheet for a focused sub-task with a clear commit/cancel; don't use one
  where inline editing would keep the user in context.
- Confirmations only for genuinely destructive/irreversible actions —
  overusing them trains users to click through blindly.
- For background completions the user isn't watching, consider a gentle,
  dismissible in-app indicator rather than a modal that steals focus.

## Settings & preferences behavior

- Changes should be **live where cheap** (theme, language) and clearly labeled
  as **"applies next run / after restart"** where they can't be. Never silently
  drop a setting change on the floor — tell the user when it takes effect.
- Persist user choices; restore them on relaunch. Losing a user's configuration
  is a trust break.

## A quick interaction checklist (run before finishing a flow)
- Does every click give feedback within ~100ms?
- Can the user cancel long work, and is cancelling safe?
- Is every destructive action either undoable or confirmed?
- On error, do we keep partial success and offer retry-from-here?
- Are empty / loading / error visually and behaviorally distinct?
- Is the main action keyboard-reachable with a sensible shortcut?
- Do disabled controls explain *why* (`.help`) instead of just being dead?
- Does re-running resume rather than redo?

## Anti-patterns to fix on sight
- A button that does heavy work synchronously and freezes the window.
- "Processing…" with no progress, no cancel, no idea if it's stuck.
- Destructive actions with no undo and no confirmation.
- Errors that only say "Failed" with no cause and no next step.
- Hiding (instead of disabling) temporarily-unavailable actions.
- A confirmation dialog on every trivial action (confirmation fatigue).
- Settings that change nothing until an unexplained restart.

Aim for flows a first-time user can't get stuck in and an expert can fly
through. When in doubt, protect the user's work and tell them what's happening.
