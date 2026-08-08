---
name: macos-ui-design
description: >
  Refine and polish native macOS SwiftUI app UI so it looks and feels like a
  well-crafted, modern Mac app that follows Apple's Human Interface Guidelines.
  Use this whenever you are adding or changing SwiftUI views, screens, sidebars,
  toolbars, sheets, settings panes, lists, empty states, buttons, or any visual
  layout in a macOS app — even if the user just says "make it look nicer",
  "clean this up", "more polished", "more native", or is building a new screen.
  This is for AppKit/SwiftUI native macOS apps, NOT web pages or HTML artifacts.
---

# Refining native macOS (SwiftUI) UI

Your goal is to make the app feel like it was built by someone with taste who
respects the Mac platform: quiet, consistent, legible, and native. Most "ugly"
Mac SwiftUI apps aren't ugly because of one big mistake — they're death by a
thousand inconsistencies: random paddings, mixed control sizes, ad-hoc colors,
custom chrome that fights the system. The fix is discipline, not decoration.

Read this whole file, then apply the parts relevant to the view you're touching.
Prefer small, surgical changes that raise consistency over dramatic redesigns.

## The five principles (in priority order)

1. **Be native before being clever.** Use system components (`Form`, `List`,
   `.formStyle(.grouped)`, `NavigationSplitView`, `Table`, `Settings` scene,
   `ContentUnavailableView`, `Menu`, `Toolbar`, `LabeledContent`) and system
   materials/colors. A stock component styled well beats a bespoke one. Custom
   chrome is a liability you maintain forever and it dates fast.

2. **Respect the semantic color & material system.** Never hardcode greys or
   `Color(hex:)` for UI chrome. Use `.primary`/`.secondary`/`.tertiary`,
   `Color.accentColor`, and semantic backgrounds: `.background`,
   `.regularMaterial`/`.thinMaterial`/`.bar`. These adapt to light/dark, vibrancy,
   increased contrast, and the user's accent color for free. Reserve real color
   for meaning (status, destructive, brand), not decoration.

3. **One spacing & type rhythm.** Pick a spacing scale and stick to it:
   4 / 8 / 12 / 16 / 20 / 24. Group with 8–12 inside a cluster, 16–24 between
   clusters. Use the system type ramp (`.largeTitle`→`.caption2`) semantically —
   never a raw `.system(size:)` for standard text. Secondary text is `.caption`
   + `.foregroundStyle(.secondary)`, not grey `.font(.system(size: 11))`.

4. **Typographic hierarchy carries the UI, not boxes.** Before adding a border,
   card, or divider, try weight, size, and color instead. A `.headline` over a
   `.secondary` `.caption` reads as a group without any container. Add borders/
   fills only when grouping truly needs a visual boundary, and then prefer
   `.background(.quaternary)` / rounded rects with hairline `.separator`.

5. **Restraint and consistency.** Same action → same icon, label, placement
   everywhere. One accent. Few weights. Generous whitespace. Animations are
   short and standard (`.snappy`/`.smooth`, ~0.2s). If a screen feels busy, the
   fix is usually *remove*, not *add*.

## Concrete SwiftUI recipes

### Windows, sidebars, layout
- Primary layout is `NavigationSplitView { sidebar } detail: { … }`. Give the
  sidebar a sensible width: `.navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)`.
- Sidebar content is usually a `List` (for navigation/items) or `Form`
  `.formStyle(.grouped)` (for settings-like controls). Don't hand-roll a VStack
  of buttons when a `List`/`Form` gives you spacing, selection, and hover for free.
- Detail/content backgrounds: let them be `.background` (default). Use
  `.regularMaterial` only for floating/overlay chrome (HUDs, bars over media).

### Toolbar
- Put primary window actions in `.toolbar { ToolbarItem(placement: .primaryAction) { … } }`.
- Toolbar buttons are icon-first `Label("Title", systemImage: …)` with a `.help("…")`
  tooltip. Titles matter — they show in overflow and accessibility.
- Keep the toolbar to a handful of items. Group related ones with
  `ToolbarItemGroup`. Don't put low-frequency actions here — those live in menus.

### Buttons & controls
- Choose button prominence deliberately: exactly one `.borderedProminent`
  primary per context; secondary actions are `.bordered`; inline/repeated row
  actions are `.borderless` or `.plain`.
- Set `.controlSize(.large)` for a focal call-to-action, `.small` for dense
  utility rows. Be consistent within a pane.
- Destructive actions use `role: .destructive`. Cancel uses `role: .cancel`
  and `.keyboardShortcut(.cancelAction)`; the default action gets
  `.keyboardShortcut(.defaultAction)`.
- Icons: SF Symbols only, chosen to actually match the action. Pair a symbol
  with a text label unless space is truly tight (then keep the accessibility
  label via `Label` + `.labelStyle(.iconOnly)`).

### Lists, rows, tables
- For scannable data, prefer `Table` (sortable columns, native selection) or a
  `List` with clean rows. In a row: leading identity, a flexible-width middle,
  trailing actions pinned right with a `Spacer(minLength:)`.
- Row secondary metadata: `.font(.caption)` `.foregroundStyle(.secondary)`,
  `.monospacedDigit()` for times/counts so they don't jitter.
- Right-click affordances belong in `.contextMenu`; mirror the most common one
  or two as always-visible trailing buttons for discoverability.

### Empty & loading states
- Always design the empty state. Use `ContentUnavailableView("Title",
  systemImage: …, description: Text("one calm sentence"))`. It's the first
  thing users see — make it inviting, not a blank void.
- Loading/progress: `ProgressView(value:)` with a short status line; keep the
  message specific and quiet.

### Sheets, settings, dialogs
- Settings live in the `Settings { … }` scene as a `TabView` of `Form`s
  (`.formStyle(.grouped)`), each tab a focused topic with an SF Symbol
  `tabItem`. Keep tab count small.
- Sheets: fixed sensible width (`~460–560`), a title, grouped `Form` body,
  and a trailing button row (Cancel + prominent primary). Don't let sheets
  auto-size awkwardly.
- Confirmations: `.confirmationDialog` for destructive/irreversible choices,
  with a clear title phrased as the question and a `.destructive` verb button.

### Color, status, feedback
- Status dots/labels: `.green` OK, `.orange` attention, `.red` error, and
  `.secondary` for neutral/idle. Keep a legend consistent across the app.
- Never rely on color alone — pair with an SF Symbol or text so it survives
  color-blindness and grayscale.

### Motion & focus
- Wrap state-driven layout changes in `withAnimation(.snappy) { … }` or
  `.animation(.smooth, value:)`. Avoid animating on high-frequency updates
  (e.g., per-frame or sub-second data) — it looks noisy and costs performance.
- Respect focus: give text fields sensible `.textFieldStyle(.roundedBorder)`
  and default focus; support keyboard (Return/Escape) in sheets.

## A quick review checklist (run before finishing a screen)
- Every text style comes from the semantic ramp; no raw `.system(size:)` for body text.
- Every chrome color is semantic (`.secondary`, `.accentColor`, materials) — no hardcoded greys.
- Paddings are on the 4/8/12/16/20/24 scale and consistent between siblings.
- Exactly one prominent primary action per context; control sizes consistent.
- Icons match actions and are reused consistently for the same action.
- There's a real empty state and a real loading state.
- Times/counts are `.monospacedDigit()`; secondary metadata is `.caption`/`.secondary`.
- Nothing custom is doing a job a stock component does better.

## Anti-patterns to fix on sight
- Hardcoded `Color(.sRGB…)`/hex or fixed greys for chrome → semantic colors.
- `.font(.system(size: 13))` for standard labels → `.body`/`.callout`/`.caption`.
- A hand-built VStack of `Button`s where a `List`/`Form` belongs.
- Multiple prominent buttons competing in one view.
- Inconsistent paddings (e.g., 10 here, 14 there, 7 elsewhere).
- Borders/cards used for grouping that typography alone would handle.
- Animating a value that updates many times per second.

Keep changes tasteful and reversible. When in doubt, remove decoration and let
the system's defaults and your typographic hierarchy do the work.
