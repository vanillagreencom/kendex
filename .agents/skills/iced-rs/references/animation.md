# Animation

Read when scheduling or debugging animated Iced 0.14 widgets. Use `animation-easing.md` for interpolation and transition controls. Start with the closest bundled example and `guide-animated-layout.md` when geometry changes.

## Invalidation

Paint-only changes, such as color, opacity or rotation within fixed bounds, request a redraw. Changes to size, position, clipping bounds or child geometry also invalidate layout.

```rust
if state.animation.is_animating(now) {
    shell.request_redraw();
    // Include this when layout geometry changes:
    shell.invalidate_layout();
}
```

The pinned [Shell declaration](https://github.com/iced-rs/iced/blob/0.14.0/core/src/shell.rs) separates these requests. The [runtime UserInterface](https://github.com/iced-rs/iced/blob/0.14.0/runtime/src/user_interface.rs) owns layout and calls the widget's layout method on invalidation. A redraw alone can paint against old geometry. When an animation appears to update only on a second click, check layout invalidation in the state-flip handler.

## Redraw vs rebuild

A redraw repaints the current widget tree; it does not itself call application `view()` to construct new widget values. Store per-frame custom-widget state in `Tree::state` and read it in layout/draw. Widget fields set by `view()` stay unchanged until the next rebuild.

For application-level transitions, keep the animation in application state and drive update/view with messages or tasks. Bare widget redraw requests do not reread that application state. `guide-animation-debugging.md` covers the resulting frozen-value symptom.

## Scheduling

Request the first redraw when starting a widget animation. On each `RedrawRequested(now)`, advance its state, invalidate geometry when needed and request another frame while it is moving. Stop requests when it finishes; idle widgets must not keep a redraw loop alive.

Choose one next-frame request:

- `request_redraw()` asks for the next available frame.
- `request_redraw_at(instant)` asks for a scheduled frame.

Shell keeps the earliest request according to [RedrawRequest ordering](https://github.com/iced-rs/iced/blob/0.14.0/core/src/window/redraw_request.rs). An immediate request takes priority over a timed one, so calling both does not establish a fixed cadence. A requested deadline alone proves neither deterministic timing nor native vsync behavior.

## Interpolation

Use `Animation<bool>` for a transition between two endpoints, or generic `interpolate_with` for projected values. Retarget with `go_mut` and check continuity when the target changes mid-transition. `animation-easing.md` owns the API patterns; keep mutable custom-widget animation state in the tree.

For trading UI, use `EaseInOut` for state transitions and `EaseOutCubic` for arrivals. Avoid bounce and elastic curves on trading surfaces.

Use hand-written elapsed-time interpolation when the widget needs explicit per-frame values, shared progress across fields or custom interruption behavior. Retain the start instant, origin, target and current value. On retarget, use the current value as the new origin. Clamp elapsed progress to the duration, apply the easing curve, settle to the exact target and clear the start instant at completion. Use a saturating elapsed-time calculation when instants can arrive out of order.

Extract a reusable reveal/collapse widget when at least two components need the same behavior. It owns tree state, redraw and layout invalidation; callers set the desired expanded state. Keep its public controls limited to that shared need.

## Bundled examples

| Task | Read |
|---|---|
| Bool transitions with opacity and scale | `examples/gallery/src/main.rs` |
| A custom widget's hand-written animation and redraw loop | `examples/loading_spinners/src/circular.rs` |
| Canvas arc animation | `examples/arc/src/main.rs` |
| Timer-driven Canvas clock | `examples/clock/src/main.rs` |
| Frame-driven Canvas animation | `examples/solar_system/src/main.rs` |
| Timed toast expiry and overlay event forwarding | `examples/toast/src/main.rs` |

These are source-reading routes. The reference snapshot has no workspace manifest and is not a local build or native timing/rendering result.

## Related references

- `advanced-shell.md`
- `subscription.md`
- `time.md`
- `guide-animated-layout.md`
- `guide-animation-debugging.md`
- `guide-custom-widgets.md`
