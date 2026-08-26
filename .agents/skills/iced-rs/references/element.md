# Element

> `iced::Element` · iced 0.14.0

Generic container for any widget. The return type of `view()`. Produced by calling `.into()` on any widget. Generic over `'a` (borrow lifetime), `Message`, `Theme`, and `Renderer`.

## API

Definition (abbreviated):

```rust
pub struct Element<'a, Message, Theme, Renderer> { /* private fields */ }

impl<'a, Message, Theme, Renderer> Element<'a, Message, Theme, Renderer> {
    pub fn new(widget: impl Widget<Message, Theme, Renderer> + 'a) -> Self;
    pub fn map<B>(self, f: impl Fn(Message) -> B + 'a) -> Element<'a, B, Theme, Renderer>
    where
        Message: 'a,
        B: 'a;
    pub fn explain(self, color: impl Into<Color>) -> Self;
    pub fn as_widget(&self) -> &dyn Widget<Message, Theme, Renderer>;
    pub fn as_widget_mut(&mut self) -> &mut dyn Widget<Message, Theme, Renderer>;
}
```

Every widget provides `From<Widget> for Element`, so widget trees end with `.into()`.

## Patterns

Typical view function:

```rust
use iced::widget::{button, column, text};
use iced::Element;

fn view(counter: &Counter) -> Element<'_, Message> {
    column![
        text(counter.value).size(20),
        button("Increment").on_press(Message::Increment),
    ]
    .spacing(10)
    .into()
}
```

Message mapping:

```rust
// In a parent view:
child_component.view().map(Message::Child)
```

Debug layout explanation:

```rust
// Wrap the entire tree to draw layout bounds in red:
element.explain(Color::from_rgb(1.0, 0.0, 0.0))
```

## Gotchas

- The `Element` returned by `view()` **must have the same `Message` type**
  as `update()`. Forgetting a `.map(...)` when composing child components
  is the classic type-mismatch bug.
- `Element` **borrows** from the app state via `'a`. Don't try to store
  `Element`s in long-lived state — they only live until the next `view()`
  call.
- `.into()` requires the target type to be inferable. When Rust can't infer,
  specify with `Element::from(widget)` or pin down the `Message` type.
- `Element::new(widget)` is rarely used directly — prefer `.into()` through
  the `From` impls each widget provides.
- No way to iterate an `Element`'s children from outside -- `as_widget()` exposes state tree, not child elements.

## See also

- `advanced-widget.md`
- `application.md`
- `widget-column-row.md`
