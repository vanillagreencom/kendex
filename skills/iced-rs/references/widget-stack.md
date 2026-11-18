# Stack

> `iced::widget::stack` · iced 0.14.0

Layers multiple children on top of each other. Children are drawn in order -- later children appear on top. The first child determines the stack's intrinsic size.

## API

Iced 0.14.0 owns the declarations, bounds, feature gates and defaults: [widget/src/stack.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/stack.rs); [widget/src/helpers.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/helpers.rs).

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
- `Stack::from_vec` does not inspect child sizing hints. Set width or height explicitly when using it with fill-sized children. `with_children` and `push` inspect the base child.
- `clip(true)` introduces a slight rendering overhead; only enable when children genuinely overflow.
- Children receive events in reverse draw order (top child first). If a top child captures an event, lower children will not see it.

## See also

- `widget-float.md` -- floating content with translation/scaling
- `widget-pin.md` -- absolute positioning within a container
- `widget-container.md` -- single-child wrapper with alignment
- `guide-animated-layout.md` -- anti-pattern: duplicated animated trees in stack
- `guide-custom-overlays.md` -- `stack + opaque` modal pattern
- `widgets.md` -- widget catalog
