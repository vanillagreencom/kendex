# Widget Catalog

Full Iced 0.14 widget catalog. One-line descriptions + canonical example per widget. Load the per-widget API reference (listed in `INDEX.md`) when you need signatures.

## Layout widgets

| Widget | Purpose | Key notes | Canonical example |
|---|---|---|---|
| `column` | Vertical stack | `spacing`, `align_x`, `max_width` | `counter`, `tour` |
| `row` | Horizontal stack | `spacing`, `align_y` | `slider`, `tour` |
| `container` | Single-child wrapper with padding/alignment/style | `.style(closure)` for custom background/border | `styling` |
| `stack` | Z-axis layering (overlapping children) | Later children render on top; use with `opaque` for modals | `modal` |
| `scrollable` | Scrollable region | `on_scroll` fires on user scroll only, not initial render; use `sensor.on_resize` for initial | `scrollable` |
| `pane_grid` | Resizable docking panes with drag-and-drop | `TitleBar` width must be `Shrink` to preserve pick area | `pane_grid` |
| `responsive` | Layout that adapts to available size | Prefer `sensor` for dimension queries | — |
| `float` | Overlay-based floating content (above siblings) | Use for tooltips and popovers | `gallery` |
| `pin` | Absolute positioning within parent | Use for drag ghosts, context menus | `multi_window` |
| `table` | Data tables with columns | — | `table` |
| `center` | Center a single child | — | `tour`, `custom_widget` |
| `space` | Fixed-size empty spacer | `Space::with_width`, `Space::with_height` | many |
| `horizontal_rule` / `vertical_rule` | Divider lines | — | `styling` |
| `themer` | Override theme for a subtree | — | — |

## Input widgets

| Widget | Purpose | Key notes | Canonical example |
|---|---|---|---|
| `button` | Pressable action trigger | `on_press` fires on mouse-up (release). `on_press_maybe` for conditional enable — never conditionally wrap | `counter`, `modal` |
| `text_input` | Single-line text field | `on_input`, `on_submit`, `on_paste` | `todos`, `editor` |
| `text_editor` | Multi-line text editor with cursor, selection, undo | Backed by cosmic-text | `editor` |
| `checkbox` | Boolean toggle with check mark | `on_toggle` | `styling` |
| `radio` | Single-choice from group | `Radio::new(label, value, selected, on_click)` | `styling` |
| `toggler` | On/off switch | `on_toggle` | `styling` |
| `slider` | Range value selector (single handle) | `on_change`, `on_release` for drag-end | `slider` |
| `pick_list` | Dropdown value picker | Uses overlay internally — no custom Overlay needed | `pick_list`, `tour` |
| `combo_box` | Searchable dropdown | Uses overlay internally | `combo_box` |

## Display widgets

| Widget | Purpose | Key notes | Canonical example |
|---|---|---|---|
| `text` | Static text display | `.size`, `.font`, `.color`, `.align_x`, `.align_y`. `text!("{}", x)` macro shorthand | many |
| `rich_text` | Styled spans of text with inline formatting | Mix fonts, colors, sizes per span | — |
| `image` | Raster image display | `image(Handle::from_path(...))` or `Handle::from_memory(bytes)` | `pokedex`, `ferris` |
| `svg` | SVG vector image | `svg(Handle::from_memory(bytes))`; scalable, no rasterization artifacts | `svg` |
| `tooltip` | Hover popup on trigger | Built-in — prefer over custom `Overlay` | `tour` |
| `progress_bar` | Determinate progress | Set value 0.0-1.0 | `download_progress` |
| `qr_code` | QR code image | `qr_code(&data)` | `qr_code` |
| `markdown` | Rendered markdown | Supports code blocks, lists, headings, tables | `markdown` |

## Advanced widgets

| Widget | Purpose | Key notes | Canonical example |
|---|---|---|---|
| `canvas` | 2D drawing via `canvas::Program` trait | Path/Frame/Cache API; use for custom visualizations | `bezier_tool`, `clock`, `solar_system`, `custom_widget` (indirect) |
| `shader` | Custom wgpu pipeline via `shader::Program` trait | Full GPU control for dense rendering; 3 trait hierarchy | `custom_shader` |
| `mouse_area` | Mouse event capture region around arbitrary content | `on_press` fires on mouse-down (vs `button` on mouse-up); use for drag initiation | `loupe`, `multitouch` |
| `sensor` | Non-visual layout dimension sensor | `on_show` (initial layout) + `on_resize` (changes). Pair with `scrollable.on_scroll` for initial + ongoing dimensions | — |
| `keyed::Column` | Keyed diffing for dynamic lists | Assigns stable identity to children so state survives reorders | — |
| `lazy` | Deferred widget construction | Rebuilds child only when key changes; useful when view construction is expensive | `lazy` |
| `opaque` | Block event propagation through its child | Pair with `stack` to make a layer non-transparent to events | `modal` |
| `pop` | Remove from parent tree | — | — |
| `value` | Display a value (debug-inspection) | Debugging aid | — |

## Selection rules

### Click vs drag

| Need | Use |
|---|---|
| Simple click → message | `button.on_press` |
| Click on an arbitrary element (label, image, container) | `mouse_area(content).on_press(msg)` |
| Drag-initiate (mouse-down) with optional drag state machine | `mouse_area(content).on_press(msg)` + `listen_with` subscription |
| Drag-end (mouse-up) in addition to drag-start | `mouse_area(...).on_release(msg)` or state machine via `listen_with` |

`button.on_press` fires on **mouse-up** (release). `mouse_area.on_press` fires on **mouse-down** (press). Pick based on whether you want click vs drag semantics.

### Conditional behavior

Never wrap conditionally:

```rust
// WRONG — tree shape changes, breaks event tracking
if enabled { mouse_area(label).into() } else { label.into() }

// RIGHT — always wrap, conditionally attach the handler
let mut area = mouse_area(label);
if enabled {
    area = area.on_press(msg);
}
area
```

`MouseArea` has **no `on_press_maybe`** — that method is `button`-specific (see row above). `MouseArea::on_press` takes a plain `Message`, not an `Option`, so gate the `.on_press(...)` call itself while keeping the wrapper unconditional.

### Overlay / floating content

1. Simple tooltip → `tooltip` widget
2. Dropdown → `pick_list` or `combo_box`
3. Modal dialog → `stack![base, opaque(modal)]`
4. Drag ghost → `pin` or `float`
5. Complex popover → `float`
6. None of the above fit → `iced::advanced::overlay::Overlay` (last resort)

See `guide-custom-overlays.md` for the custom Overlay contract.

### Text display

- Plain text: `text("hello")` or `text!("count: {}", n)` macro
- Mixed styles on one line: `rich_text` with spans
- Multi-line editable: `text_editor`
- Single-line editable: `text_input`
- Markdown from a string: `markdown(...)`
- SVG icon text / monospace decoration: `svg` with inline SVG data

### Font and sizing

```rust
text("symbol").size(14).font(Font::MONOSPACE)
```

`Font::MONOSPACE` resolves to the first loaded monospace font at application startup. For named system fonts, use `Font::with_name("JetBrains Mono")`. Load custom fonts via the application builder:

```rust
iced::daemon(boot, State::update, State::view)
    .font(include_bytes!("../fonts/JetBrainsMono-Regular.ttf"))
```

For apps with a design system, route all text through a typography role layer rather than hard-coding `size()` / `font()` at each call site.

## Event handling reference

| Event source | Fires on | Captured by |
|---|---|---|
| `button.on_press` | Mouse-up over the button | `button` |
| `mouse_area.on_press` | Mouse-down over the area | `mouse_area` |
| `mouse_area.on_release` | Mouse-up | `mouse_area` |
| `mouse_area.on_move` | Cursor move inside area | `mouse_area` |
| `mouse_area.on_enter` / `on_exit` | Cursor enter / exit boundary | `mouse_area` |
| `scrollable.on_scroll` | User scroll only (not initial render) | `scrollable` |
| `sensor.on_show` | First layout where sensor is visible | `sensor` |
| `sensor.on_resize` | Layout size change | `sensor` |
| `text_input.on_input` | Per keystroke | `text_input` |
| `text_input.on_submit` | Enter key | `text_input` |

Anything not handled by a specific widget event goes through the global `Subscription` API (`iced::event::listen`, `keyboard::listen`, etc.) — use subscriptions for application-level keyboard shortcuts, window focus events, and event-inspection patterns.

## When to write a custom widget

Default: use the existing widgets + `.style(closure)` for custom visuals.

Write a custom `iced::advanced::Widget` when **any** of these is true:
- You need persistent Tree state across frames (hover, drag phase, animation accumulator)
- You need non-rectangular hit-testing
- You need to compose child widgets with a custom layout algorithm
- You need events the built-ins don't expose
- You need to produce an overlay from your widget's own logic

See `guide-custom-widgets.md` for the full checklist.

## See also

- `guide-surface-selection.md` — when to use built-in widgets vs custom
- `guide-custom-widgets.md` — building a custom `iced::advanced::Widget`
- `guide-custom-overlays.md` — building a custom overlay
- `animation.md` — animation patterns for widget transitions
