# Button

Read when adding an action, controlling its availability or styling its interaction states in Iced 0.14.0.

Use `button` for an action that publishes a message on release. The [pinned implementation](https://raw.githubusercontent.com/iced-rs/iced/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/button.rs) owns `Button`, its handlers, sizing, padding, clipping, status, style, catalog and defaults. The [widget helpers](https://raw.githubusercontent.com/iced-rs/iced/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/helpers.rs) own the `button` constructor.

## Use

```rust
use iced::widget::button;

button("Delete")
    .on_press(Message::Delete)
    .style(button::danger)
```

Without a handler, the button is disabled. Use `on_press_maybe` to control availability while keeping the widget present:

```rust
button("Save")
    .on_press_maybe(valid.then_some(Message::Save))
```

Use `on_press_with(|| expensive_message())` when constructing the message is costly. The closure runs when an accepted activation publishes the message. Converting the button to an `Element` requires a cloneable message type.

Follow the skill's [widget tree consistency rule](../SKILL.md#widget-tree-consistency) when attaching interaction wrappers.

## Interaction and style

The button updates its child first. If the child captures the event, the button does not handle it. An enabled button records a left-mouse or touch press over its bounds. It publishes only after that recorded press is released over the button. Touch loss clears the pressed state. For mouse-down handling, use [mouse-area](widget-mouse-area.md).

Use `.style(button::primary)` or another pinned style function for a theme variant. A custom closure receives the theme and interaction status. Start from a status-aware style to keep its text color and disabled appearance, then change the fields the design needs:

```rust
button("Custom")
    .on_press(Message::Confirm)
    .style(|theme, status| button::Style {
        border: iced::border::rounded(6),
        ..button::primary(theme, status)
    })
```

`.class(...)` requires the `advanced` feature. `.style(...)` uses the catalog's conversion from a style closure; see [Catalog](catalog.md).

## Related references

- [Widgets](widgets.md): choose a built-in widget.
- [Element](element.md): composition and message mapping.
