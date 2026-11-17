# Shell

> `iced::advanced::Shell` · iced 0.14.0

Communication channel between a widget and the iced runtime during `update()`. Publishes messages, requests redraws, captures events, invalidates layout, and merges child shells.

Read when implementing or debugging shell behavior in a custom widget or backend. Enable Iced’s `advanced` feature for the `iced::advanced` paths used here.

## Declarations

Pinned Iced 0.14.0 declarations, signatures, defaults and implementation:

- [core/src/shell.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/shell.rs).

## Patterns

Emitting a message on click:

```rust
fn update(
    &mut self,
    _tree: &mut Tree,
    event: &Event,
    layout: Layout<'_>,
    cursor: Cursor,
    _renderer: &Renderer,
    _clipboard: &mut dyn Clipboard,
    shell: &mut Shell<'_, Message>,
    _viewport: &Rectangle,
) {
    if let Event::Mouse(mouse::Event::ButtonPressed(mouse::Button::Left)) = event {
        if cursor.is_over(layout.bounds()) {
            shell.publish((self.on_press)());
            shell.capture_event();
        }
    }
}
```

Animation redraws:

```rust
shell.request_redraw();

shell.request_redraw_at(window::RedrawRequest::At(
    std::time::Instant::now() + std::time::Duration::from_millis(16),
));
```

## Gotchas

- Call `capture_event()` when handling a mouse press or parents will also react ("drag is also firing a click" bugs).
- `invalidate_widgets()` requests rebuilding and relayout of the widget tree. Prefer `invalidate_layout()` when only geometry changed.
- `request_redraw()` requests the next frame. `request_redraw_at()` keeps the earliest pending request.
- IME requests are silently dropped outside `window::Event::RedrawRequested`.
- `merge()` takes ownership of the other shell -- design composite widgets with a sub-shell that merges into the parent.

## See also

- `advanced-widget.md`
- `advanced-overlay.md`
- `advanced-tree.md`
- `events.md`
- `animation.md` — redraw vs rebuild invariant, invalidation modes
