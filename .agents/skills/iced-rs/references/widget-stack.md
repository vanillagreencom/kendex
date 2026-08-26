# Stack

> `iced::widget::stack` · iced 0.14.0

Layers multiple children on top of each other. Children are drawn in order -- later children appear on top. The stack sizes itself to its largest child by default.

## API

### `Stack` struct

```rust
pub struct Stack<'a, Message, Theme = Theme, Renderer = Renderer<Renderer, Renderer>>
{ /* private fields */ }

impl<'a, Message, Theme, Renderer> Stack<'a, Message, Theme, Renderer>
where
    Renderer: Renderer,
{
    pub fn new() -> Self;
    pub fn with_children(
        children: Vec<Element<'a, Message, Theme, Renderer>>,
    ) -> Self;

    pub fn push(
        self,
        child: impl Into<Element<'a, Message, Theme, Renderer>>,
    ) -> Self;
    pub fn push_under(
        self,
        child: impl Into<Element<'a, Message, Theme, Renderer>>,
    ) -> Self;
    pub fn extend(
        self,
        children: impl IntoIterator<Item = Element<'a, Message, Theme, Renderer>>,
    ) -> Self;

    pub fn width(self, width: impl Into<Length>) -> Self;
    pub fn height(self, height: impl Into<Length>) -> Self;
    pub fn clip(self, clip: bool) -> Self;
}
```

### Functions

```rust
pub fn stack<'a, Message, Theme, Renderer>(
    children: impl IntoIterator<Item = Element<'a, Message, Theme, Renderer>>,
) -> Stack<'a, Message, Theme, Renderer>
where
    Renderer: Renderer;
```

## Patterns

### Overlay text on an image

```rust
use iced::widget::{stack, image, text, container};
use iced::Fill;

stack![
    image("background.png").width(Fill).height(Fill),
    container(text("Overlay Label").size(24))
        .center_x(Fill)
        .center_y(Fill),
]
```

### Background layer with `push_under`

```rust
use iced::widget::{stack, container, text};
use iced::{Fill, Color};

stack(vec![text("Foreground").into()])
    .push_under(
        container("")
            .width(Fill)
            .height(Fill)
            .style(|_| container::Style {
                background: Some(Color::from_rgb(0.1, 0.1, 0.1).into()),
                ..Default::default()
            })
    )
```

### Clip overflowing children

```rust
stack![widget_a, widget_b].clip(true)
```

## Gotchas

- `push_under` places the element *beneath* existing children without affecting the stack's intrinsic size. Use it for decorative backgrounds.
- If any child uses `Length::Fill`, you must explicitly set `Stack::width` or `Stack::height` -- the stack does not auto-detect fill children from a `Vec`.
- `clip(true)` introduces a slight rendering overhead; only enable when children genuinely overflow.
- Children receive events in reverse draw order (top child first). If a top child captures an event, lower children will not see it.

## See also

- `widget-float.md` -- floating content with translation/scaling
- `widget-pin.md` -- absolute positioning within a container
- `widget-container.md` -- single-child wrapper with alignment
- `guide-animated-layout.md` -- anti-pattern: duplicated animated trees in stack
- `guide-custom-overlays.md` -- `stack + opaque` modal pattern
- `widgets.md` -- widget catalog
