---
name: iced-rs
description: "Iced 0.14 GUI framework expert — custom widgets via iced::advanced, overlays, Canvas, Shader, pane_grid, theming, subscriptions, Elm architecture. Load whenever building, modifying, or debugging any Iced UI. Bundled reference library covers the full 0.14 API; bundled examples include all upstream iced examples plus the iced_wgpu renderer source."
license: MIT
user-invocable: true
metadata:
  author: vanillagreen
  source: vstack
  repository: "https://github.com/vanillagreencom/vstack"
  bugs: "https://github.com/vanillagreencom/vstack/issues"
  version: "3.0.0"
---

# Iced 0.14

> **Problem with this skill?** Run `vstack report` — it files to the owning repo automatically. Do not hand-file.

Framework skill for building any Iced 0.14 UI.

## Reading order

1. `references/INDEX.md` — all reference files, load-on-demand
2. `references/guide-surface-selection.md` — built-in vs Canvas vs Shader vs Widget vs Overlay
3. `references/guide-custom-widgets.md` — custom `iced::advanced::Widget`
4. `references/guide-custom-overlays.md` — custom `iced::advanced::overlay::Overlay`
5. `references/guide-animated-layout.md` — animated expand/collapse, layered views, variable-height animated lists
6. `references/guide-animation-debugging.md` — animation/render bug diagnosis

Raw API references (`advanced-*.md`, `canvas.md`, `shader.md`, etc.) as needed.

## Bundled resources

### `references/` — 75 API + guide files

Load on demand from `references/INDEX.md`.

**Guides:**

| Guide | Use |
|---|---|
| `guide-surface-selection.md` | Pick the right primitive |
| `guide-custom-widgets.md` | `iced::advanced::Widget` |
| `guide-custom-overlays.md` | `iced::advanced::overlay::Overlay` |
| `guide-animated-layout.md` | Animated transitions, measured positions, keyed identity, clipping |
| `guide-animation-debugging.md` | Symptom→cause checklist for animation/render bugs |

**API refs:** `advanced-*.md`, `canvas*.md`, `shader.md`, `element.md`, `length.md`, `padding.md`, `alignment.md`, `task.md`, `subscription.md`, `application.md`, `window.md`, `keyboard.md`, `mouse.md`, `theme*.md`, `catalog.md`, `pane-grid.md`, `api-module-tree.md`

### `examples/` — 56 upstream Iced 0.14 examples

Read the canonical one before writing similar code — 0.14 signatures differ from 0.13.

| Need | Read first |
|---|---|
| Custom Widget impl | `examples/custom_widget/src/main.rs` |
| GPU shader pipeline | `examples/custom_shader/` (full dir) |
| Mesh / vector geometry widget | `examples/geometry/src/main.rs` |
| Canvas 2D drawing | `examples/bezier_tool`, `examples/clock`, `examples/color_palette` |
| Canvas animation | `examples/solar_system`, `examples/the_matrix`, `examples/game_of_life` |
| Arc/ring animation | `examples/loading_spinners`, `examples/arc` |
| Modal dialog | `examples/modal/src/main.rs` (stack + opaque) |
| Toast/notification overlay | `examples/toast/src/main.rs` |
| Tooltip / zoom-on-hover | `examples/loupe/src/main.rs` |
| Styled components | `examples/styling/` |
| pane_grid layout | `examples/pane_grid/` |
| Multi-window | `examples/multi_window/` |
| WebSocket subscription | `examples/websocket/` |
| Text editing | `examples/editor/` |

### `iced_wgpu/` — iced's own wgpu renderer source

Full `iced_wgpu` crate source. Reference for wgpu pipeline patterns.

| File | Use |
|---|---|
| `iced_wgpu/src/engine.rs` | Device/Queue per-frame lifecycle |
| `iced_wgpu/src/layer.rs` | Layer composition |
| `iced_wgpu/src/quad.rs`, `quad/solid.rs`, `quad/gradient.rs` | Instanced quad pipeline template |
| `iced_wgpu/src/triangle.rs`, `triangle/msaa.rs` | Mesh pipeline with MSAA |
| `iced_wgpu/src/primitive.rs` | Custom shader primitive interface |
| `iced_wgpu/src/buffer.rs` | Resizable growable buffer pattern |
| `iced_wgpu/src/shader/quad.wgsl` | Reference WGSL for instanced quads |

### External fallbacks (prefer local — pinned to 0.14.0)

- `ctx7 docs /websites/rs_iced_iced "<query>"` — newer API surface
- `https://docs.rs/iced/0.14.0/iced/` — authoritative API reference
- `https://github.com/iced-rs/iced` — upstream master (may have unreleased APIs)

## Dev tools

| Tool | Purpose | Install |
|---|---|---|
| `cargo-hot` | Live UI patching | `cargo install cargo-hot` |
| `comet` | Debugger: frame metrics, widget tree, message inspector | `cargo install --locked --git https://github.com/iced-rs/comet.git` |

`features = ["debug"]` + F12 for built-in debugger. Stress-test with `ICED_PRESENT_MODE=Immediate` + `unconditional-rendering`. Profile with `iced::debug::time`:

```rust
fn update(&mut self, message: Message) -> Task<Message> {
    iced::debug::time(format!("{message:?}"), || match message { /* ... */ })
}
```

## Breaking changes from Iced 0.13

Common compile errors when porting or generating from memory:

- `Widget::update` takes `event: &Event` (by ref, not by value)
- `Widget::layout` takes `&mut Tree`
- Entry points split: `iced::daemon(boot, update, view)` multi-window, `iced::application(new, update, view)` single-window
- Shrink prioritized over Fill in layout resolution
- Theme palette uses Oklch
- Keyboard subscriptions unified into `keyboard::listen`

## Surface Selection

Full tree: `references/guide-surface-selection.md`.

1. **Standard UI** → built-in widgets + `.style(closure)`
2. **2D custom drawing** → `Canvas`
3. **GPU-dense rendering** → `Shader`
4. **Custom events/state/overlays/layout** → `iced::advanced::Widget`
5. **Floating layer** → try `tooltip`, `float`, `stack`+`opaque` first; custom `Overlay` only as last resort

## Widget catalog

Full API in `references/`.

**Layout**: `column`, `row`, `container`, `stack`, `scrollable`, `pane_grid`, `responsive`, `float`, `pin`, `table`, `center`, `space`, `horizontal_rule`/`vertical_rule`, `themer`

**Input**: `button`, `text_input`, `text_editor`, `checkbox`, `radio`, `toggler`, `slider`, `pick_list`, `combo_box`

**Display**: `text`, `rich_text`, `image`, `svg`, `tooltip`, `progress_bar`, `qr_code`, `markdown`

**Advanced**: `canvas`, `shader`, `mouse_area`, `sensor`, `keyed::Column`, `lazy`, `opaque`, `pop`, `value`

- `button.on_press` fires on mouse-up; `mouse_area.on_press` fires on mouse-down (drag initiation)
- `sensor.on_show` on initial layout + `on_resize` on changes; combine with `scrollable.on_scroll`
- `scrollable.on_scroll` fires only on user scroll, not initial render
- `float` → overlay-based; `pin` → absolute positioning

## Patterns

### Subscriptions

```rust
fn subscription(&self) -> Subscription<Message> {
    Subscription::batch(self.sources.iter().map(|source| {
        Subscription::run_with(source.id, data_stream).map(Message::DataReceived)
    }))
}
```

Stable identity via `run_with(id, ...)` or `.with(id)`. See `references/subscription.md`.

### Theming

Built-in palette: `primary`, `success`, `danger`, `warning`. Use `LazyLock<AppTokens>` sidecar for custom tokens (see Theme rule below).

```rust
Theme::custom_with_fn("My Dark", palette, |p| theme::palette::Extended::generate(p))

pub struct AppTokens {
    pub surface: [Color; 5],
    pub border: Color,
    pub border_width: f32,
    pub border_radius: f32,
    // ...
}
pub static TOKENS: LazyLock<AppTokens> = LazyLock::new(|| { /* ... */ });

pub fn panel_container(_theme: &iced::Theme) -> container::Style {
    let t = &*TOKENS;
    container::Style {
        background: Some(iced::Background::Color(t.surface[1])),
        border: iced::Border { color: t.border, width: t.border_width, radius: t.border_radius.into() },
        ..Default::default()
    }
}
```

Route every visual value through `TOKENS`.

Font loading:

```rust
iced::daemon(boot, State::update, State::view)
    .font(include_bytes!("../fonts/JetBrainsMono-Regular.ttf"))
```

`Font::MONOSPACE` → first loaded monospace font. `Font::with_name("...")` for system fonts. See `references/theme.md`, `references/theme-palette.md`, `references/catalog.md`.

### Elm architecture

Message enum and State struct in root module. Extracted modules receive `&State` or `&mut State`.

**Extract when**: feature-gated + self-contained, OR cohesive responsibility group, OR >30 lines on a well-defined State subset.

### Multi-window

`window::open(settings) -> Task<window::Id>`, `window::close(id)`. See `references/window.md`.

### Testing

`iced_test`: `Simulator` (headless widget), `Emulator` (full runtime), snapshot support.

### PaneGrid

- `button` and `mouse_area` both `capture_event()` on press. Tab elements capture → custom tab drag. Empty title bar → native pane_grid drag.
- Tab drag: `mouse_area.on_press` per tab + `listen_with` for `CursorMoved`/`ButtonReleased`. Idle → Pressed(origin) → Dragging (8px threshold).

## Rules (non-negotiable framework invariants)

### Widget tree consistency

Iced tracks widgets by tree position. Conditional wrapping changes tree shape and breaks event tracking.

```rust
// WRONG: conditional wrapping changes tree shape
if dragging { mouse_area(label).into() } else { label.into() }

// RIGHT: always wrap, conditionally attach the handler
let mut area = mouse_area(label);
if enable {
    area = area.on_press(msg);
}
area
```

`MouseArea` has no `on_press_maybe` — its `on_press` takes a plain `Message`, so gate the call, not the wrapper. (`on_press_maybe(Option<Message>)` is `button`-only.)

### view() is pure

No side effects, no memoization dependent on call frequency. All mutable state in `State`, mutated only in `update()`. Never trigger redraws from `view()`.

### Scroll state initialization

`scrollable.on_scroll` fires only after scrolling, not at initial layout. Use `sensor.on_resize` for initial dimensions.

### Minimum pane size

`PaneGrid::min_size` is uniform. Per-pane minimums must be enforced in pane content or split/resize state.

### Animation invalidation

- **Paint-only** (color, opacity, rotation with fixed bounds): `shell.request_redraw()`
- **Layout-affecting** (size, position, expand/collapse, clipping bounds): `shell.request_redraw()` + `shell.invalidate_layout()`

**Diagnostic**: widget "only updates on the second click" → stale layout, add `invalidate_layout()`.

### Redraw vs rebuild

`request_redraw()` repaints but does **not** call `view()`. Animation state must live in `widget::Tree` state — widget struct fields are frozen between `view()` calls. See `references/animation.md` § "Redraw vs rebuild."

### Draw order is z-order

In custom widget `draw()`, child iteration order determines z-order. Last drawn = on top. `stack` semantics do not apply inside manual draw loops.

### Hover stability

Hover sensors must not wrap content whose size changes during the animation they trigger — animated bounds cause enter/exit thrashing. Use a stable outer hitbox. See `references/guide-custom-widgets.md` § "Stable hover hit regions."

### Overlay state isolation

Overlay layers (`stack` children beyond the base) must not affect base-layer widget structure. Never change base-layer construction based on overlay presence.

### Pick area geometry (pane_grid)

TitleBar content must use `Shrink` width so empty space remains for the pick area. `Fill` width eliminates it.

```rust
// WRONG
pane_grid::TitleBar::new(row![tabs].width(Length::Fill))
// RIGHT
pane_grid::TitleBar::new(row![tabs].width(Length::Shrink))
```

### Single message per interaction

One widget interaction → one message. Composite actions (tab press → drag) use a state machine in `update()`.

### Title bar event ordering (pane_grid)

In `pane_grid::Content::update` the title bar processes before the body. Do not unconditionally clear state in body-exit handlers that the title bar just established.

### Overlay visibility requires layout invalidation

Widgets that conditionally return an overlay must call `shell.invalidate_layout()` when visibility changes. Otherwise stale layout → panic.

```rust
Event::Mouse(mouse::Event::CursorEntered) => {
    if !self.show_overlay {
        self.show_overlay = true;
        shell.invalidate_layout(); // required
    }
}
```

### Custom overlays are the #1 panic source

Prefer built-ins (`tooltip`, `float`, `stack`+`opaque`). Custom overlays cause `container.rs unwrap() on None` when the contract is violated.

**Custom overlay contract**: `children()` → fixed count; `diff()` → reconcile all children regardless of visibility; `layout()` → nodes matching children; `draw()` → same tree from layout. Full spec: `references/guide-custom-overlays.md`.

### Overlay viewport contract

When calling descendant `Widget` methods from inside an `Overlay` impl, pass `Rectangle::INFINITE` as viewport, **never** the stored viewport from parent's `overlay()`. `scrollable::overlay` forwards `bounds.intersection(viewport)`, and `iced_wgpu`'s text scissor turns inherited clips into invisible text. `Overlay::layout()` may still use `bounds: Size` for its own coordinate space.

### Subscription — stable identity

Each data source needs stable identity via `run_with(id, ...)` or `.with(id)`. Without it, torn down + recreated every view cycle.

### Subscription — bounded update work

Pre-aggregate high-frequency data in the subscription worker. Emit one batch per non-empty ~16ms window. Use bounded channels with `try_send()` producer-side.

### Theme — no custom theme type for tokens

`Theme::Custom` cannot attach custom data; custom Theme type requires 15-20 Catalog impls. Use `LazyLock<AppTokens>` sidecar. Custom Theme type only when runtime theme switching is needed.

### Overlay starvation

Stacked `mouse_area(...).interaction(...)` layers can block underlying hover/move handlers even without `opaque(...)`. Set `Interaction::Grabbing` on the real drag target. Use `opaque(...)` only for true capture zones.

### PaneGrid drag feedback

Keep drag feedback inside the picked pane subtree or `pane_grid::Style`. `mouse_area`/`opaque` pane-drag overlays are rebuild-sensitive and can prevent `Dropped` events. Drag previews must reuse the same TitleBar/body shell.

### Split interaction ownership

When `mouse_area` handles semantics while `button` provides visual feedback, exactly one layer must publish the action:

```rust
// RIGHT: mouse_area owns semantics; button is visual-only
mouse_area(button(content)).on_press(Message::Activate)

// WRONG: both layers publish
mouse_area(button(content).on_press(Message::Activate)).on_press(Message::Activate)
```

### Cache staleness — trace before coding

When adding cached or mirrored UI state, enumerate every mutation path that can stale it before writing code.

### Cache staleness — extend existing event paths

Extend the existing global event path rather than adding parallel subscriptions for the same event family.

### Cache staleness — regression tests

Add at least one regression test for each non-obvious cache invalidation or source-window gate.

## Hot workflow

1. Classify: `references/guide-surface-selection.md`. Do not skip.
2. Read canonical example in `examples/`.
3. Read relevant guide (`guide-custom-widgets.md`, `guide-custom-overlays.md`).
4. **Animated layered UI**: read `references/guide-animated-layout.md` first.
5. Skim API references the guide points to.
6. Write code.
7. Stuck: guide "Common failure modes" / "Gotchas". Top 3 bugs: missing `capture_event`, missing `invalidate_layout`, wrong event signature (0.13 API). Animation bugs: `references/guide-animation-debugging.md`.
8. Perf: measure with `iced::debug::time` + `comet` before optimizing.
