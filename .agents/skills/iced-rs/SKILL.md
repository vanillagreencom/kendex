---
name: iced-rs
description: "Load whenever building or debugging an Iced UI."
summary: "Iced 0.14 GUI reference: custom widgets via iced::advanced, overlays, Canvas, Shader, pane_grid, theming, subscriptions, Elm architecture, with a bundled full-API reference."
license: MIT
user-invocable: true
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
  version: "3.0.0"
tags: [ui]
---

<!-- kendex:project-instructions:start -->
## Project Instructions

<!-- kendex:shared-instructions:start -->
Problems with a kendex-owned skill go through `kendex report`; check ownership in the file first.
<!-- kendex:shared-instructions:end -->
<!-- kendex:project-instructions:end -->

# Iced 0.14

## Workflow

1. Classify the surface against `references/guide-surface-selection.md`. Do not skip.
2. Read the canonical example in `examples/`, never generate 0.14 code from memory.
3. Read the guide for that surface; for animated layered UI, `references/guide-animated-layout.md` comes first.
4. Stuck: the guide's "Common failure modes" / "Gotchas", then `references/guide-animation-debugging.md` for animation and render bugs. The three most common: missing `capture_event`, missing `invalidate_layout`, 0.13 event signatures.

Surface choice: built-in widgets + `.style(closure)` for standard UI; `Canvas` for 2D custom drawing; `Shader` for GPU-dense rendering; `iced::advanced::Widget` for custom events, state, or layout; for a floating layer try `tooltip`, `float`, or `stack`+`opaque` before a custom `Overlay`.

## Bundled resources

### `references/`: API refs and guides

Full list in `references/INDEX.md`; load on demand.

| Guide | Use |
|---|---|
| `guide-surface-selection.md` | Pick the right primitive |
| `guide-custom-widgets.md` | `iced::advanced::Widget` |
| `guide-custom-overlays.md` | `iced::advanced::overlay::Overlay` |
| `guide-animated-layout.md` | Animated transitions, measured positions, keyed identity, clipping |
| `guide-animation-debugging.md` | Symptom→cause checklist for animation/render bugs |
| `widgets.md` | Widget catalog: every 0.14 widget, notes, canonical example |

### `examples/`: every upstream Iced 0.14 example

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

### `iced_wgpu/` and external fallbacks

Renderer source for shader work: `iced_wgpu/src/` (`engine.rs`, `layer.rs`, `quad.rs`, `quad/solid.rs`, `quad/gradient.rs`, `triangle.rs`, `triangle/msaa.rs`, `primitive.rs`, `buffer.rs`, `shader/quad.wgsl`). Local references are pinned to 0.14.0; prefer them. For newer API surface: `ctx7 docs /websites/rs_iced_iced "<query>"`, `https://docs.rs/iced/0.14.0/iced/`, or upstream master at `https://github.com/iced-rs/iced` (may have unreleased APIs).

## Breaking changes from Iced 0.13

- `Widget::update` takes `event: &Event` (by ref, not by value)
- `Widget::layout` takes `&mut Tree`
- Keyboard subscriptions unified into `keyboard::listen`

## Rules (non-negotiable framework invariants)

### Widget tree consistency

Conditional wrapping changes tree shape and breaks event tracking. Always wrap; conditionally attach the handler.

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

`MouseArea` has no `on_press_maybe` (`button`-only); gate the `on_press` call, not the wrapper.

### view() is pure

No side effects, no memoization dependent on call frequency. All mutable state lives in `State` and is mutated only in `update()`. Never trigger redraws from `view()`.

### Redraw vs rebuild

`request_redraw()` repaints but does **not** call `view()`. Animation state must live in `widget::Tree` state. Widget struct fields are frozen between `view()` calls. See `references/animation.md` § "Redraw vs rebuild."

### Animation invalidation

Paint-only changes (color, opacity, rotation within fixed bounds) need `shell.request_redraw()`. Layout-affecting changes (size, position, expand/collapse, clipping bounds) need `shell.request_redraw()` **and** `shell.invalidate_layout()`. A widget that "only updates on the second click" has stale layout. Add `invalidate_layout()`.

### Draw order is z-order

In custom widget `draw()`, child iteration order determines z-order; last drawn is on top. `stack` semantics do not apply inside manual draw loops.

### Overlay visibility requires layout invalidation

A widget that conditionally returns an overlay must call `shell.invalidate_layout()` when visibility changes.

### Custom overlays are the #1 panic source

Prefer built-ins (`tooltip`, `float`, `stack`+`opaque`). A violated contract panics as `container.rs unwrap() on None`. The contract: `children()` returns a fixed count; `diff()` reconciles all children regardless of visibility; `layout()` returns nodes matching children; `draw()` walks the same tree layout produced. Full spec: `references/guide-custom-overlays.md`.

### Overlay viewport contract

When calling descendant `Widget` methods from inside an `Overlay` impl, pass `Rectangle::INFINITE` as the viewport, **never** the stored viewport from the parent's `overlay()`. `Overlay::layout()` may still use `bounds: Size` for its own coordinate space.

### Overlay state isolation

Overlay layers (`stack` children beyond the base) must not affect base-layer widget structure. Never change base-layer construction based on overlay presence.

### Overlay starvation

Stacked `mouse_area(...).interaction(...)` layers can block underlying hover/move handlers even without `opaque(...)`. Set `Interaction::Grabbing` on the real drag target, and reserve `opaque(...)` for true capture zones.

### Hover stability

Hover sensors must not wrap content whose size changes during the animation they trigger. Use a stable outer hitbox. See `references/guide-custom-widgets.md` § "Stable hover hit regions."

### Scroll state initialization

`scrollable.on_scroll` fires only after user scrolling, never at initial layout. Use `sensor.on_show` for initial layout and `sensor.on_resize` for changes.

### Single message per interaction

One widget interaction produces one message. Composite actions (tab press becoming a drag) use a state machine in `update()`. When `mouse_area` handles semantics while `button` provides visual feedback, exactly one layer publishes: `mouse_area` owns the semantics and `button` stays visual-only.

`button.on_press` fires on mouse-up; `mouse_area.on_press` fires on mouse-down. Use it for drag initiation.

### pane_grid

- `PaneGrid::min_size` is uniform. Per-pane minimums must be enforced in pane content or in split/resize state.
- TitleBar content must use `Shrink` width so empty space remains for the pick area; `Fill` eliminates it.
- `button` and `mouse_area` both `capture_event()` on press: tab elements capturing means a custom tab drag, an empty title bar means native pane_grid drag.
- Tab drag is `mouse_area.on_press` per tab plus `listen_with` for `CursorMoved`/`ButtonReleased`, with an Idle → Pressed(origin) → Dragging state machine at an 8px threshold.
- In `pane_grid::Content::update` the title bar processes before the body. Do not unconditionally clear state in body-exit handlers that the title bar just established.
- Keep drag feedback inside the picked pane subtree or in `pane_grid::Style`. `mouse_area`/`opaque` pane-drag overlays are rebuild-sensitive and can prevent `Dropped` events; drag previews must reuse the same TitleBar/body shell.

### Subscriptions

Each data source needs stable identity: `Subscription::run_with(id, stream)` or `.with(id)`, batched with `Subscription::batch`. See `references/subscription.md`.

Pre-aggregate high-frequency data in the subscription worker: emit one batch per non-empty ~16ms window, over bounded channels with producer-side `try_send()`.

### Theming: no custom Theme type for tokens

Build the palette with `Theme::custom_with_fn("My Dark", palette, |p| theme::palette::Extended::generate(p))`, keep app tokens in a `LazyLock<AppTokens>` sidecar, and route every visual value through it from style closures that ignore the passed `&Theme`. Introduce a custom `Theme` type only when runtime theme switching demands it.

Built-in palette roles are `primary`, `success`, `danger`, `warning`. Fonts load on the entry point (`.font(include_bytes!(...))`); `Font::MONOSPACE` resolves to the first loaded monospace font and `Font::with_name("...")` to a system font. See `references/theme.md`, `references/theme-palette.md`, `references/catalog.md`.

### Cache staleness

Before writing cached or mirrored UI state, enumerate every mutation path that can stale it. Extend the existing global event path rather than adding a parallel subscription for the same event family; add at least one regression test per non-obvious invalidation or source-window gate.

## Architecture

`Message` enum and `State` struct live in the root module; extracted modules receive `&State` or `&mut State`. Extract when a feature is gated and self-contained, forms a cohesive responsibility group, or exceeds ~30 lines over a well-defined `State` subset.

Multi-window: `window::open(settings) -> Task<window::Id>`, `window::close(id)`. See `references/window.md`. Testing: `iced_test` provides `Simulator` (headless widget), `Emulator` (full runtime), and snapshot support.

## Dev tools

`cargo-hot`, `comet`, the built-in F12 debugger, stress-test switches, and `iced::debug::time`: `references/debug.md`.
