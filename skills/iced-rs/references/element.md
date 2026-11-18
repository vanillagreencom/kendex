# Element

> `iced::Element` · iced 0.14.0

Generic container for any widget. The return type of `view()`. Use `.into()` for a widget with an `Element` conversion or wrap a custom widget using `Element::new`. Generic over `'a` (borrow lifetime), `Message`, `Theme`, and `Renderer`.

Read when returning a widget from a view or mapping child messages.

## API

Read the [Iced 0.14.0 declarations](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/element.rs) for signatures and available types.

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

- The `Element` returned by `view()` **must have the same `Message` type** as `update()`. Forgetting a `.map(...)` when composing child components is the classic type-mismatch bug.
- An `Element` may borrow data for `'a`. Return borrowed elements from `view()` without extending their source data's lifetime; owned elements can have a longer lifetime.
- `.into()` requires the target type to be inferable. When Rust can't infer, specify with `Element::from(widget)` or pin down the `Message` type.
- `Element::new(widget)` is rarely used directly — prefer `.into()` through the `From` impls each widget provides.
- `as_widget()` exposes the wrapped `Widget`, not its runtime state `Tree` or a list of child elements.

## See also

- `advanced-widget.md`
- `application.md`
- `widget-column-row.md`
