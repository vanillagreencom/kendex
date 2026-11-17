# Pin

> `iced::widget::pin` · iced 0.14.0

Positions content at fixed coordinates inside its boundaries. Use when you need pixel-precise absolute positioning within a parent container.

## API

Iced 0.14.0 owns the declarations, bounds, feature gates and defaults: [widget/src/pin.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/pin.rs); [widget/src/helpers.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/helpers.rs).

## Patterns

### Place at fixed coordinates

```rust
use iced::widget::pin;

pin("This text is at (50, 50)!")
    .x(50)
    .y(50)
```

### Position with a Point

```rust
use iced::widget::pin;
use iced::Point;

pin(my_widget).position(Point::new(100.0, 200.0))
```

### Pin inside a stack for absolute overlays

```rust
use iced::widget::{stack, pin, text};
use iced::Fill;

stack![
    background_content,
    pin(text("Pinned label"))
        .x(10)
        .y(10)
        .width(Fill)
        .height(Fill),
]
```

## Gotchas

- `Pin` positions content relative to its own boundaries, not the window. Combine with `stack` or a fill-sized container to get window-relative positioning.
- If neither `x`/`y` nor `position` is set, content defaults to (0, 0).
- Drawing passes the intersection of the pin bounds and the parent viewport to the content.

## See also

- `widget-stack.md` -- layering multiple children
- `widget-float.md` -- floating with translation/scale
- `advanced-layout.md` -- `Node::move_to` for custom widget positioning
- `widgets.md` -- widget catalog
