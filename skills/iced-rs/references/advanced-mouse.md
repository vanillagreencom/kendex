# Cursor and click handling

Read when implementing custom-widget hit testing or cursor feedback in Iced 0.14.0. The pinned [cursor](https://github.com/iced-rs/iced/blob/0.14.0/core/src/mouse/cursor.rs), [interaction](https://github.com/iced-rs/iced/blob/0.14.0/core/src/mouse/interaction.rs) and [click](https://github.com/iced-rs/iced/blob/0.14.0/core/src/mouse/click.rs) declarations own the API. The public `iced::mouse::Cursor` re-export exposes cursor methods; they do not require the advanced module's feature gate.

## Coordinates and visibility

`position_over(bounds)` returns an absolute point inside the rectangle. `position_in(bounds)` subtracts its origin and returns a local point. `position_from(origin)` supplies relative coordinates without the same rectangle containment check.

```rust
if let Some(local) = cursor.position_in(layout.bounds()) {
    // Use local coordinates for the widget's geometry.
}
```

Unavailable and levitating cursors produce no available position. `land()` changes a levitating cursor back to available for the layer that owns it; do not land it merely to bypass another layer's capture.

Rectangle hit testing alone does not test viewport visibility. Include the viewport when interaction must stop outside visible content. Store previous hover state when the widget needs enter/leave transitions.

## Feedback and clicks

Return an interaction only in the region that should own that cursor feedback. `None` is the default absence of an interaction; distinguish it from explicit `Idle`. Check overlay and parent handling when a cursor choice suppresses underlying hover. `guide-custom-overlays.md` owns layered input guidance.

Keep the previous `Click` in widget state and pass it with the new position and button to `Click::new`. The click helper classifies consecutive presses by button, timing and proximity, then exposes their kind and position. It is not an unconditional runtime promotion of every mouse event. The declaration owns thresholds and the sequence after a triple click.

```rust
let click = iced::advanced::mouse::Click::new(
    position,
    iced::mouse::Button::Left,
    state.last_click,
);
let kind = click.kind();
state.last_click = Some(click);
```

Use the resulting kind to choose single-, double- or triple-click behavior, and capture the event when ancestors must not act on it too. Check native pointer and hover behavior in the target application.

## Related references

- `mouse.md`
- `advanced-widget.md`
- `advanced-shell.md`
- `guide-custom-overlays.md`
