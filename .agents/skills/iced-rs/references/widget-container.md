# Container

> `iced::widget::container` · iced 0.14.0

A single-child wrapper that aligns, pads, sizes, and styles its contents. The most frequently used layout widget in iced — think "div" with padding and alignment.

## API

### `Container` struct

```rust
pub struct Container<'a, Message, Theme = Theme, Renderer = Renderer<Renderer, Renderer>>
where
    Theme: Catalog,
    Renderer: Renderer,
{ /* private fields */ }

impl<'a, Message, Theme, Renderer> Container<'a, Message, Theme, Renderer>
where
    Theme: Catalog,
    Renderer: Renderer,
{
    pub fn new(
        content: impl Into<Element<'a, Message, Theme, Renderer>>,
    ) -> Self;

    pub fn id(self, id: impl Into<Id>) -> Self;
    pub fn padding<P: Into<Padding>>(self, padding: P) -> Self;
    pub fn width(self, width: impl Into<Length>) -> Self;
    pub fn height(self, height: impl Into<Length>) -> Self;
    pub fn max_width(self, max_width: impl Into<Pixels>) -> Self;
    pub fn max_height(self, max_height: impl Into<Pixels>) -> Self;

    // Sizing + alignment combinators
    pub fn center_x(self, width: impl Into<Length>) -> Self;
    pub fn center_y(self, height: impl Into<Length>) -> Self;
    pub fn center(self, length: impl Into<Length>) -> Self;
    pub fn align_left(self, width: impl Into<Length>) -> Self;
    pub fn align_right(self, width: impl Into<Length>) -> Self;
    pub fn align_top(self, height: impl Into<Length>) -> Self;
    pub fn align_bottom(self, height: impl Into<Length>) -> Self;

    pub fn align_x(self, alignment: impl Into<Horizontal>) -> Self;
    pub fn align_y(self, alignment: impl Into<Vertical>) -> Self;

    pub fn clip(self, clip: bool) -> Self;

    pub fn style(self, style: impl Fn(&Theme) -> Style + 'a) -> Self
    where
        <Theme as Catalog>::Class<'a>: From<Box<dyn Fn(&Theme) -> Style + 'a>>;

    pub fn class(self, class: impl Into<<Theme as Catalog>::Class<'a>>) -> Self;
}
```

### `Style` struct

```rust
pub struct Style {
    pub text_color: Option<Color>,
    pub background: Option<Background>,
    pub border: Border,
    pub shadow: Shadow,
    pub snap: bool,
}

impl Style {
    pub fn color(self, color: impl Into<Color>) -> Style;
    pub fn border(self, border: impl Into<Border>) -> Style;
    pub fn background(self, background: impl Into<Background>) -> Style;
    pub fn shadow(self, shadow: impl Into<Shadow>) -> Style;
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

### Type aliases

```rust
pub type StyleFn<'a, Theme> = Box<dyn Fn(&Theme) -> Style + 'a>;
```

### Functions

```rust
pub fn container<'a, Message, Theme, Renderer>(
    content: impl Into<Element<'a, Message, Theme, Renderer>>,
) -> Container<'a, Message, Theme, Renderer>;

// Pre-made style functions
pub fn transparent(theme: &Theme) -> Style;
pub fn rounded_box(theme: &Theme) -> Style;
pub fn bordered_box(theme: &Theme) -> Style;
pub fn dark(theme: &Theme) -> Style;
pub fn background(theme: &Theme) -> Style;
pub fn primary(theme: &Theme) -> Style;
pub fn secondary(theme: &Theme) -> Style;
pub fn success(theme: &Theme) -> Style;
pub fn warning(theme: &Theme) -> Style;
pub fn danger(theme: &Theme) -> Style;

// Advanced helpers
pub fn draw_background(/* renderer, style, bounds */);
pub fn layout(/* ... */) -> layout::Node;
```

## Patterns

### Centered rounded card

```rust
use iced::widget::container;

container("Centered content")
    .padding(10)
    .center(800)
    .style(container::rounded_box)
```

### Pad + align

```rust
container(column![row1, row2, row3].spacing(8))
    .padding(16)
    .width(Length::Fill)
    .align_x(alignment::Horizontal::Center)
```

### Custom style

```rust
container(content)
    .padding(12)
    .style(|theme| container::Style {
        background: Some(theme.extended_palette().background.weak.color.into()),
        border: border::rounded(4.0).width(1.0).color(theme.palette().primary),
        ..container::Style::default()
    })
```

### Top-level layout

```rust
container(main_view)
    .width(Length::Fill)
    .height(Length::Fill)
    .padding(0)
```

## Gotchas

- `center(length)` is equivalent to chaining `center_x(length).center_y(length)` — it sets both axes to the same length.
- The `style` closure is `Fn(&Theme) -> Style`, not `Fn(&Theme, Status)` — containers have no status (they are non-interactive).
- Without `clip(true)`, an overflowing child is rendered outside the container's bounds. Use `clip(true)` for scroll masks and overflow protection.
- `text_color: None` means "inherit from parent"; set it explicitly to override.
- The `id` method lets you target the container with `operate(Operation)` — e.g., programmatic scrolling, focus management.

## See also

- `catalog.md` — the `Catalog` trait pattern
- `widget-scrollable.md` — when content overflows and you want scrolling
- `widget-stack.md` — for z-axis layering (overlap)
- `length.md` — `Length::Fill`/`Shrink`/`Fixed` sizing
- `padding.md` — `Padding` struct
