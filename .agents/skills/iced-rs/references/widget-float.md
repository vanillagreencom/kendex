# Float

> `iced::widget::float` · iced 0.14.0

Allows content to float over other widgets with optional scaling and custom translation logic. Useful for tooltips, floating action buttons, and overlays that need dynamic positioning.

## API

### `Float` struct

```rust
pub struct Float<'a, Message, Theme = Theme, Renderer = Renderer<Renderer, Renderer>>
where
    Theme: Catalog,
{ /* private fields */ }

impl<'a, Message, Theme, Renderer> Float<'a, Message, Theme, Renderer>
where
    Theme: Catalog,
    Renderer: Renderer,
{
    pub fn new(
        content: impl Into<Element<'a, Message, Theme, Renderer>>,
    ) -> Self;

    pub fn scale(self, scale: f32) -> Self;

    pub fn translate(
        self,
        translate: impl Fn(Rectangle, Rectangle) -> Vector + 'a,
    ) -> Self;

    pub fn style(
        self,
        style: impl Fn(&Theme) -> Style + 'a,
    ) -> Self
    where
        <Theme as Catalog>::Class<'a>: From<Box<dyn Fn(&Theme) -> Style + 'a>>;

    pub fn class(
        self,
        class: impl Into<<Theme as Catalog>::Class<'a>>,
    ) -> Self; // feature = "advanced"
}
```

### `Style` struct

```rust
pub struct Style {
    pub shadow: Shadow,
}
```

### `Catalog` trait

```rust
pub trait Catalog {
    type Class<'a>;
    fn default<'a>() -> Self::Class<'a>;
    fn style(&self, class: &Self::Class<'_>) -> Style;
}
```

### Functions

```rust
pub fn float<'a, Message, Theme, Renderer>(
    content: impl Into<Element<'a, Message, Theme, Renderer>>,
) -> Float<'a, Message, Theme, Renderer>
where
    Theme: Catalog,
    Renderer: Renderer;
```

## Patterns

### Floating action button

```rust
use iced::widget::{button, container, float, text};
use iced::{Element, Fill};

float(
    container("Main Content").width(Fill).height(Fill),
    button("FAB").on_press(Message::FloatingClicked),
)
```

### Custom translation (bottom-right anchor)

```rust
use iced::widget::float;
use iced::Vector;

float(content)
    .translate(|bounds, viewport| {
        Vector::new(
            viewport.width - bounds.width - 16.0,
            viewport.height - bounds.height - 16.0,
        )
    })
```

### Scaled floating content

```rust
float(minimap_widget).scale(0.5)
```

## Gotchas

- The `translate` closure receives the original bounds of the floating content and the viewport bounds. Returning `Vector::ZERO` keeps the content at its natural position.
- `scale` values greater than 1.0 enlarge; less than 1.0 shrink. The scale is applied to the center of the content.
- Float does not participate in the parent layout -- it overlays. If you need layout-aware positioning, use `pin` or `stack` instead.

## See also

- `widget-stack.md` -- layering without translation
- `widget-pin.md` -- fixed-coordinate positioning
- `widget-tooltip.md` -- built-in tooltip overlay
- `advanced-overlay.md` -- custom overlay API
