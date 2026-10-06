# A behaviour spec is not an architecture doc

A file found under `docs/architecture/` that writes up what a window does, control by control. The test in [../SKILL.md](../SKILL.md) § One home per fact sorts every line of it out of `docs/`.

## Not this

```markdown
# The Settings window

Covers: shell/plugins/settings/**, scripts/smoke/rows/settings.sh

- **Surface.** A floating window titled Plugins, centred on the focused monitor, `min(size.window.width, screen width − 2 × size.window.gutter)` wide and `size.window.heightShare` of the screen tall. The gear, the `SUPER+M` shortcut and the IPC open it; a click on the gear focuses the gear's monitor first.
- **Pages.** The list page holds a search field and one row per plugin; the plugin page holds a back button, Open for a window plugin, and two tabs, Settings and Details. Escape pops the page, then closes the window. A page with an unsaved edit asks once, Save, Discard or Cancel, before it is left.
- **Keyboard.** The search field takes the initial focus. Printable keys typed elsewhere on the list focus it and append the text. Up, Down, PageUp, PageDown, Ctrl+Home and Ctrl+End move the cursor; Return opens the highlighted plugin; Ctrl+S saves every unsaved edit.
- **Fields.** One field per schema entry, in manifest order. A boolean draws a switch; an enum with at most three options a segmented control, a larger one a select; a bounded number a slider. A switch writes at once; a text field waits for Save.

## Invariants

1. The window lists every plugin the manager lists, with the same enabled state. Enforced by `scripts/smoke/rows/settings.sh`, which reads the rows back.
2. An edit in progress survives an unrelated configuration change. Enforced by `scripts/smoke/rows/settings.sh`.
3. Each open rescans, so a status row shows the system's current state. Not yet enforced.

## Decisions

[D032](../decisions/D032-settings-in-manifest.md), [D050](../decisions/D050-container-layout.md).
```

## Where each line goes

| Line | Home | Why |
|---|---|---|
| The window's size, its openers, the pages, the keys and the field per schema type | The code under `shell/plugins/settings/` and the test `scripts/smoke/rows/settings.sh` that holds it | What a page, key or button does is the feature. The code shows it, the test holds it, and a copy in a doc is wrong at the next change. |
| Invariants 1 and 2, with their "Enforced by" | The tests named, which already hold them | A line whose only content is "this test checks this" tells an agent nothing the test does not. |
| Invariant 3, "Not yet enforced" | A test item on the tracker | A behaviour no test holds is a missing test, never a doc. The item names the behaviour and the test that will hold it. |
| The "Decisions" list | Nothing | A list of IDs beside no rule is an index. `decisions search` finds a record, and a principle doc cites an ID beside the rule that carries it out. |
| "A page with an unsaved edit asks once before it is left" | A principle doc on forms, where one reader's task already needs one: "Never leave a page with an unsaved edit without one prompt; `scripts/smoke/rows/settings.sh` presses Escape over an edit and reads the prompt." | The one rule in the file an agent writing any page could break unknowingly. It is kept only where such a doc has a reader's task; a doc is not created to hold one line. |

The file is deleted. Nothing in it answered the question an architecture doc exists for: what work an agent does with it open, and what breaks without it.
