---
name: iced-rs
description: "Iced 0.14 GUI expert: custom widgets via iced::advanced, overlays, Canvas, Shader, pane_grid, theming, subscriptions, Elm architecture, with a bundled full-API reference. Load whenever building or debugging an Iced UI."
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

## Workflow

1. Classify the surface against `references/guide-surface-selection.md`. Do not skip.
2. Read the canonical example in `examples/` — 0.14 signatures differ from 0.13, and generating from memory produces 0.13 code.
3. Read the guide for that surface; for animated layered UI, `references/guide-animated-layout.md` comes first.
4. Stuck: the guide's "Common failure modes" / "Gotchas", then `references/guide-animation-debugging.md` for animation and render bugs. The three most common: missing `capture_event`, missing `invalidate_layout`, 0.13 event signatures.

Surface choice: built-in widgets + `.style(closure)` for standard UI; `Canvas` for 2D custom drawing; `Shader` for GPU-dense rendering; `iced::advanced::Widget` for custom events, state, or layout; for a floating layer try `tooltip`, `float`, or `stack`+`opaque` before a custom `Overlay`.

## Bundled resources

### `references/` — API refs and guides

Full list in `references/INDEX.md`; load on demand.

| Guide | Use |
|---|---|
| `guide-surface-selection.md` | Pick the right primitive |
| `guide-custom-widgets.md` | `iced::advanced::Widget` |
| `guide-custom-overlays.md` | `iced::advanced::overlay::Overlay` |
| `guide-animated-layout.md` | Animated transitions, measured positions, keyed identity, clipping |
| `guide-animation-debugging.md` | Symptom→cause checklist for animation/render bugs |
| `widgets.md` | Widget catalog: every 0.14 widget, notes, canonical example |

API refs: `advanced-*.md`, `widget-*.md`, `canvas*.md`, `shader.md`, `element.md`, `length.md`, `padding.md`, `alignment.md`, `task.md`, `subscription.md`, `application.md`, `window.md`, `keyboard.md`, `mouse.md`, `theme*.md`, `catalog.md`, `pane-grid.md`, `animation*.md`, `api-module-tree.md`.

### `examples/` — every upstream Iced 0.14 example

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

| File | Use |
|---|---|
| `iced_wgpu/src/engine.rs` | Device/Queue per-frame lifecycle |
| `iced_wgpu/src/layer.rs` | Layer composition |
| `iced_wgpu/src/quad.rs`, `quad/solid.rs`, `quad/gradient.rs` | Instanced quad pipeline template |
| `iced_wgpu/src/triangle.rs`, `triangle/msaa.rs` | Mesh pipeline with MSAA |
| `iced_wgpu/src/primitive.rs` | Custom shader primitive interface |
| `iced_wgpu/src/buffer.rs` | Resizable growable buffer pattern |
| `iced_wgpu/src/shader/quad.wgsl` | Reference WGSL for instanced quads |

### External fallbacks

Local references are pinned to 0.14.0 — prefer them. For newer API surface: `ctx7 docs /websites/rs_iced_iced "<query>"`, `https://docs.rs/iced/0.14.0/iced/`, or upstream master at `https://github.com/iced-rs/iced` (may have unreleased APIs).

## Breaking changes from Iced 0.13

- `Widget::update` takes `event: &Event` (by ref, not by value)
- `Widget::layout` takes `&mut Tree`
- Entry points split: `iced::daemon(boot, update, view)` multi-window, `iced::application(new, update, view)` single-window
- Shrink prioritized over Fill in layout resolution
- Theme palette uses Oklch
- Keyboard subscriptions unified into `keyboard::listen`

## Rules (non-negotiable framework invariants)

### Widget tree consistency

Iced tracks widgets by tree position, so conditional wrapping changes tree shape and breaks event tracking. Always wrap; conditionally attach the handler.

```rust
// WRONG: conditional wrapping changes tree shape
if dragging { mouse_area(label).into() } else { label.into() }

// RIGHT
let mut area = mouse_area(label);
if enable {
    area = area.on_press(msg);
}
area
```

`MouseArea` has no `on_press_maybe` — its `on_press` takes a plain `Message`, so gate the call, not the wrapper. (`on_press_maybe(Option<Message>)` is `button`-only.)

### view() is pure

No side effects, no memoization dependent on call frequency. All mutable state lives in `State` and is mutated only in `update()`. Never trigger redraws from `view()`.

### Redraw vs rebuild

`request_redraw()` repaints but does **not** call `view()`. Animation state must live in `widget::Tree` state — widget struct fields are frozen between `view()` calls. See `references/animation.md` § "Redraw vs rebuild."

### Animation invalidation

Paint-only changes (color, opacity, rotation within fixed bounds) need `shell.request_redraw()`. Layout-affecting changes (size, position, expand/collapse, clipping bounds) need `shell.request_redraw()` **and** `shell.invalidate_layout()`. A widget that "only updates on the second click" has stale layout — add `invalidate_layout()`.

### Draw order is z-order

In custom widget `draw()`, child iteration order determines z-order; last drawn is on top. `stack` semantics do not apply inside manual draw loops.

### Overlay visibility requires layout invalidation

A widget that conditionally returns an overlay must call `shell.invalidate_layout()` when visibility changes, or stale layout panics.

```rust
Event::Mouse(mouse::Event::CursorEntered) => {
    if !self.show_overlay {
        self.show_overlay = true;
        shell.invalidate_layout(); // required
    }
}
```

### Custom overlays are the #1 panic source

Prefer built-ins (`tooltip`, `float`, `stack`+`opaque`). A violated contract shows up as `container.rs unwrap() on None`. The contract: `children()` returns a fixed count; `diff()` reconciles all children regardless of visibility; `layout()` returns nodes matching children; `draw()` walks the same tree layout produced. Full spec: `references/guide-custom-overlays.md`.

### Overlay viewport contract

When calling descendant `Widget` methods from inside an `Overlay` impl, pass `Rectangle::INFINITE` as the viewport, **never** the stored viewport from the parent's `overlay()`. `scrollable::overlay` forwards `bounds.intersection(viewport)`, and `iced_wgpu`'s text scissor turns inherited clips into invisible text. `Overlay::layout()` may still use `bounds: Size` for its own coordinate space.

### Overlay state isolation

Overlay layers (`stack` children beyond the base) must not affect base-layer widget structure. Never change base-layer construction based on overlay presence.

### Overlay starvation

Stacked `mouse_area(...).interaction(...)` layers can block underlying hover/move handlers even without `opaque(...)`. Set `Interaction::Grabbing` on the real drag target, and reserve `opaque(...)` for true capture zones.

### Hover stability

Hover sensors must not wrap content whose size changes during the animation they trigger — animated bounds cause enter/exit thrashing. Use a stable outer hitbox. See `references/guide-custom-widgets.md` § "Stable hover hit regions."

### Scroll state initialization

`scrollable.on_scroll` fires only after user scrolling, never at initial layout. Use `sensor.on_show` for initial layout and `sensor.on_resize` for changes.

### Single message per interaction

One widget interaction produces one message. Composite actions (tab press becoming a drag) use a state machine in `update()`. When `mouse_area` handles semantics while `button` provides visual feedback, exactly one layer publishes:

```rust
// RIGHT: mouse_area owns semantics; button is visual-only
mouse_area(button(content)).on_press(Message::Activate)

// WRONG: both layers publish
mouse_area(button(content).on_press(Message::Activate)).on_press(Message::Activate)
```

`button.on_press` fires on mouse-up; `mouse_area.on_press` fires on mouse-down, which is what makes it the drag-initiation primitive.

### pane_grid

- `PaneGrid::min_size` is uniform. Per-pane minimums must be enforced in pane content or in split/resize state.
- TitleBar content must use `Shrink` width so empty space remains for the pick area; `Fill` eliminates it.
- `button` and `mouse_area` both `capture_event()` on press: tab elements capturing means a custom tab drag, an empty title bar means native pane_grid drag. Tab drag is `mouse_area.on_press` per tab plus `listen_with` for `CursorMoved`/`ButtonReleased`, with an Idle → Pressed(origin) → Dragging state machine at an 8px threshold.
- In `pane_grid::Content::update` the title bar processes before the body. Do not unconditionally clear state in body-exit handlers that the title bar just established.
- Keep drag feedback inside the picked pane subtree or in `pane_grid::Style`. `mouse_area`/`opaque` pane-drag overlays are rebuild-sensitive and can prevent `Dropped` events; drag previews must reuse the same TitleBar/body shell.

### Subscriptions

Each data source needs stable identity — `Subscription::run_with(id, stream)` or `.with(id)`, batched with `Subscription::batch`. Without it the subscription is torn down and recreated every view cycle. See `references/subscription.md`.

Pre-aggregate high-frequency data in the subscription worker: emit one batch per non-empty ~16ms window, over bounded channels with producer-side `try_send()`.

### Theming — no custom Theme type for tokens

`Theme::Custom` cannot attach custom data, and a custom `Theme` type requires 15-20 `Catalog` impls. Build the palette with `Theme::custom_with_fn("My Dark", palette, |p| theme::palette::Extended::generate(p))`, keep app tokens in a `LazyLock<AppTokens>` sidecar, and route every visual value through it from style closures that ignore the passed `&Theme`. Introduce a custom `Theme` type only when runtime theme switching demands it.

Built-in palette roles are `primary`, `success`, `danger`, `warning`. Fonts load on the entry point (`.font(include_bytes!(...))`); `Font::MONOSPACE` resolves to the first loaded monospace font and `Font::with_name("...")` to a system font. See `references/theme.md`, `references/theme-palette.md`, `references/catalog.md`.

### Cache staleness

Before writing cached or mirrored UI state, enumerate every mutation path that can stale it. Extend the existing global event path rather than adding a parallel subscription for the same event family, and add at least one regression test per non-obvious invalidation or source-window gate.

## Architecture

`Message` enum and `State` struct live in the root module; extracted modules receive `&State` or `&mut State`. Extract when a feature is gated and self-contained, forms a cohesive responsibility group, or exceeds ~30 lines over a well-defined `State` subset.

Multi-window: `window::open(settings) -> Task<window::Id>`, `window::close(id)` — `references/window.md`. Testing: `iced_test` provides `Simulator` (headless widget), `Emulator` (full runtime), and snapshot support.

## Dev tools

| Tool | Purpose | Install |
|---|---|---|
| `cargo-hot` | Live UI patching | `cargo install cargo-hot` |
| `comet` | Debugger: frame metrics, widget tree, message inspector | `cargo install --locked --git https://github.com/iced-rs/comet.git` |

`features = ["debug"]` plus F12 enables the built-in debugger. Stress-test with `ICED_PRESENT_MODE=Immediate` and `unconditional-rendering`. Measure with `iced::debug::time` and `comet` before optimizing:

```rust
fn update(&mut self, message: Message) -> Task<Message> {
    iced::debug::time(format!("{message:?}"), || match message { /* ... */ })
}
```
