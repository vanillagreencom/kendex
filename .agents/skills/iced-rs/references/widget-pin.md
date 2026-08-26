# Pin

> `iced::widget::pin` · iced 0.14.0

Positions content at fixed coordinates inside its boundaries. Use when you need pixel-precise absolute positioning within a parent container.

## API

### `Pin` struct

```rust
pub struct Pin<'a, Message, Theme = Theme, Renderer = Renderer<Renderer, Renderer>>
where
    Renderer: Renderer,
{ /* private fields */ }

impl<'a, Message, Theme, Renderer> Pin<'a, Message, Theme, Renderer>
where
    Renderer: Renderer,
{
    pub fn new(
        content: impl Into<Element<'a, Message, Theme, Renderer>>,
    ) -> Self;

    pub fn width(self, width: impl Into<Length>) -> Self;
    pub fn height(self, height: impl Into<Length>) -> Self;

    pub fn position(self, position: impl Into<Point>) -> Self;
    pub fn x(self, x: impl Into<Pixels>) -> Self;
    pub fn y(self, y: impl Into<Pixels>) -> Self;
}
```

### Functions

```rust
pub fn pin<'a, Message, Theme, Renderer>(
    content: impl Into<Element<'a, Message, Theme, Renderer>>,
) -> Pin<'a, Message, Theme, Renderer>
where
    Renderer: Renderer;
```

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
- Content is not clipped by default. If the pinned content overflows the pin's bounds, it will draw outside.

## See also

- `widget-stack.md` -- layering multiple children
- `widget-float.md` -- floating with translation/scale
- `advanced-layout.md` -- `Node::move_to` for custom widget positioning
- `widgets.md` -- widget catalog
