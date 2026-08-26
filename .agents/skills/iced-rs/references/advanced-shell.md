# Shell

> `iced::advanced::Shell` · iced 0.14.0

Communication channel between a widget and the iced runtime during `update()`. Publishes messages, requests redraws, captures events, invalidates layout, and merges child shells.

## API

```rust
pub struct Shell<'a, Message> { /* private fields */ }

impl<'a, Message> Shell<'a, Message> {
    pub fn new(messages: &'a mut Vec<Message>) -> Shell<'a, Message>;
    pub fn is_empty(&self) -> bool;

    // Messages
    pub fn publish(&mut self, message: Message);

    // Event capture
    pub fn capture_event(&mut self);
    pub fn is_event_captured(&self) -> bool;
    pub fn event_status(&self) -> Status;

    // Redraws
    pub fn request_redraw(&mut self);
    pub fn request_redraw_at(&mut self, redraw_request: impl Into<RedrawRequest>);
    pub fn redraw_request(&self) -> RedrawRequest;
    pub fn replace_redraw_request(
        shell: &mut Shell<'_, Message>,
        redraw_request: RedrawRequest,
    );

    // Input method (IME)
    pub fn request_input_method<T>(&mut self, ime: &InputMethod<T>)
    where
        T: AsRef<str>;
    pub fn input_method(&self) -> &InputMethod;
    pub fn input_method_mut(&mut self) -> &mut InputMethod;

    // Invalidation
    pub fn is_layout_invalid(&self) -> bool;
    pub fn invalidate_layout(&mut self);
    pub fn revalidate_layout(&mut self, f: impl FnOnce());
    pub fn are_widgets_invalid(&self) -> bool;
    pub fn invalidate_widgets(&mut self);

    // Composition
    pub fn merge<B>(&mut self, other: Shell<'_, B>, f: impl Fn(B) -> Message);
}
```

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
- `invalidate_widgets()` rebuilds the entire widget tree. Prefer `invalidate_layout()` when only geometry changed.
- `request_redraw()` means "now"; `request_redraw_at()` schedules a specific time for coalescing.
- IME requests are silently dropped outside `window::Event::RedrawRequested`.
- `merge()` takes ownership of the other shell -- design composite widgets with a sub-shell that merges into the parent.

## See also

- `advanced-widget.md`
- `advanced-overlay.md`
- `advanced-tree.md`
- `events.md`
- `animation.md` — redraw vs rebuild invariant, invalidation modes
