# Layout Primitives

> `iced::widget::{center, space, horizontal_rule, vertical_rule}` · iced 0.14.0

Small layout utility widgets: centering wrappers, empty spacers, and visual dividers.

## API

### `center` function

```rust
pub fn center<'a, Message, Theme, Renderer>(
    content: impl Into<Element<'a, Message, Theme, Renderer>>,
) -> Container<'a, Message, Theme, Renderer>
where
    Theme: container::Catalog + 'a,
    Renderer: Renderer;
```

A convenience shortcut for `container(content).center_x(Fill).center_y(Fill)`. Centers content both horizontally and vertically, filling all available space.

### `space` function

```rust
pub fn space() -> Space;
```

Creates an empty `Space` widget with no size. The identity widget -- takes no space and does nothing. Use `horizontal_space()` and `vertical_space()` for directional spacers.

### `Space` struct

```rust
pub struct Space { /* private fields */ }

impl Space {
    pub fn new(width: impl Into<Length>, height: impl Into<Length>) -> Self;
    pub fn with_width(width: impl Into<Length>) -> Self;
    pub fn with_height(height: impl Into<Length>) -> Self;
}
```

### `horizontal_space` / `vertical_space` functions

```rust
pub fn horizontal_space() -> Space;  // Space::with_width(Length::Fill)
pub fn vertical_space() -> Space;    // Space::with_height(Length::Fill)
```

### `horizontal_rule` / `vertical_rule` functions

```rust
pub fn horizontal_rule(height: impl Into<Pixels>) -> Rule<'static, Theme>
where
    Theme: rule::Catalog;

pub fn vertical_rule(width: impl Into<Pixels>) -> Rule<'static, Theme>
where
    Theme: rule::Catalog;
```

### `Rule` struct

```rust
pub struct Rule<'a, Theme = Theme>
where
    Theme: Catalog,
{ /* private fields */ }

impl<'a, Theme> Rule<'a, Theme>
where
    Theme: Catalog,
{
    pub fn horizontal(height: impl Into<Pixels>) -> Self;
    pub fn vertical(width: impl Into<Pixels>) -> Self;

    pub fn style(
        self,
        style: impl Fn(&Theme) -> Style + 'a,
    ) -> Self;

    pub fn class(
        self,
        class: impl Into<<Theme as Catalog>::Class<'a>>,
    ) -> Self;
}
```

### `rule::Style` struct

```rust
pub struct Style {
    pub color: Color,
    pub width: u16,
    pub radius: Radius,
    pub fill_mode: FillMode,
}
```

## Patterns

### Center content in the window

```rust
use iced::widget::center;

center(text("Hello, world!"))
```

### Push content apart with spacers

```rust
use iced::widget::{row, text, horizontal_space};

row![
    text("Left"),
    horizontal_space(),
    text("Right"),
]
```

### Section divider

```rust
use iced::widget::{column, text, horizontal_rule};

column![
    text("Section 1"),
    horizontal_rule(1),
    text("Section 2"),
]
.spacing(8)
```

### Vertical divider between panels

```rust
use iced::widget::{row, vertical_rule};

row![
    left_panel,
    vertical_rule(1),
    right_panel,
]
```

### Styled rule

```rust
use iced::widget::rule;

rule::horizontal(2).style(|theme| rule::Style {
    color: theme.extended_palette().primary.base.color,
    width: 2,
    radius: 1.0.into(),
    fill_mode: rule::FillMode::Full,
})
```

## Gotchas

- `space()` produces a zero-size widget. Use `horizontal_space()` or `vertical_space()` to get a fill-axis spacer.
- `center()` is just a convenience over `container().center_x(Fill).center_y(Fill)`. It fills all available space.
- Rule thickness is the `height` parameter for `horizontal_rule` and `width` for `vertical_rule`. These are the cross-axis dimensions.
- Rules fill the main axis by default (`FillMode::Full`).

## See also

- `widget-container.md` -- `container` with explicit alignment/padding
- `length.md` -- `Length::Fill`, `Length::Shrink`
- `padding.md` -- `Padding` struct
- `widgets.md` -- widget catalog
