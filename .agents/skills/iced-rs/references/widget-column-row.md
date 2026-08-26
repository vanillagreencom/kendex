# Column & Row

> `iced::widget::column` + `iced::widget::row` · iced 0.14.0

The primary layout widgets. `Column` distributes children vertically; `Row` distributes children horizontally. Used in virtually every view function.

## API

### `Column` struct

```rust
pub struct Column<'a, Message, Theme = Theme, Renderer = Renderer<Renderer, Renderer>>
where Renderer: Renderer,
{ /* private fields */ }

impl<'a, Message, Theme, Renderer> Column<'a, Message, Theme, Renderer>
where Renderer: Renderer,
{
    // Constructors
    pub fn new() -> Self;
    pub fn with_capacity(capacity: usize) -> Self;
    pub fn with_children(
        children: impl IntoIterator<Item = Element<'a, Message, Theme, Renderer>>,
    ) -> Self;
    pub fn from_vec(
        children: Vec<Element<'a, Message, Theme, Renderer>>,
    ) -> Self;

    // Layout configuration
    pub fn spacing(self, amount: impl Into<Pixels>) -> Self;
    pub fn padding<P: Into<Padding>>(self, padding: P) -> Self;
    pub fn width(self, width: impl Into<Length>) -> Self;
    pub fn height(self, height: impl Into<Length>) -> Self;
    pub fn max_width(self, max_width: impl Into<Pixels>) -> Self;
    pub fn align_x(self, align: impl Into<Horizontal>) -> Self;
    pub fn clip(self, clip: bool) -> Self;

    // Children
    pub fn push(
        self,
        child: impl Into<Element<'a, Message, Theme, Renderer>>,
    ) -> Self;
    pub fn extend(
        self,
        children: impl IntoIterator<Item = Element<'a, Message, Theme, Renderer>>,
    ) -> Self;

    // Convert to wrapping layout
    pub fn wrap(self) -> Wrapping<'a, Message, Theme, Renderer>;
}
```

### `Row` struct

```rust
pub struct Row<'a, Message, Theme = Theme, Renderer = Renderer<Renderer, Renderer>>
where Renderer: Renderer,
{ /* private fields */ }

impl<'a, Message, Theme, Renderer> Row<'a, Message, Theme, Renderer>
where Renderer: Renderer,
{
    // Constructors
    pub fn new() -> Self;
    pub fn with_capacity(capacity: usize) -> Self;
    pub fn with_children(
        children: impl IntoIterator<Item = Element<'a, Message, Theme, Renderer>>,
    ) -> Self;
    pub fn from_vec(
        children: Vec<Element<'a, Message, Theme, Renderer>>,
    ) -> Self;

    // Layout configuration
    pub fn spacing(self, amount: impl Into<Pixels>) -> Self;
    pub fn padding<P: Into<Padding>>(self, padding: P) -> Self;
    pub fn width(self, width: impl Into<Length>) -> Self;
    pub fn height(self, height: impl Into<Length>) -> Self;
    pub fn align_y(self, align: impl Into<Vertical>) -> Self;
    pub fn clip(self, clip: bool) -> Self;

    // Children
    pub fn push(
        self,
        child: impl Into<Element<'a, Message, Theme, Renderer>>,
    ) -> Self;
    pub fn extend(
        self,
        children: impl IntoIterator<Item = Element<'a, Message, Theme, Renderer>>,
    ) -> Self;

    // Convert to wrapping layout
    pub fn wrap(self) -> Wrapping<'a, Message, Theme, Renderer>;
}
```

### Macros

```rust
// column! macro -- sugar for Column::new().push(a).push(b)...
macro_rules! column {
    () => { ... };
    ($($x:expr),+ $(,)?) => { ... };
}

// row! macro -- sugar for Row::new().push(a).push(b)...
macro_rules! row {
    () => { ... };
    ($($x:expr),+ $(,)?) => { ... };
}
```

### Free functions

```rust
pub fn column<'a, Message, Theme, Renderer>(
    children: impl IntoIterator<Item = Element<'a, Message, Theme, Renderer>>,
) -> Column<'a, Message, Theme, Renderer>;

pub fn row<'a, Message, Theme, Renderer>(
    children: impl IntoIterator<Item = Element<'a, Message, Theme, Renderer>>,
) -> Row<'a, Message, Theme, Renderer>;
```

## Patterns

### Basic vertical layout

```rust
use iced::widget::{column, text, button};

column![
    text("Title").size(24),
    text("Subtitle").size(14),
    button("Action").on_press(Message::Go),
]
.spacing(8)
.padding(16)
```

### Basic horizontal layout

```rust
use iced::widget::{row, text, button};

row![
    text("Label"),
    button("OK").on_press(Message::Ok),
    button("Cancel").on_press(Message::Cancel),
]
.spacing(12)
.align_y(iced::alignment::Vertical::Center)
```

### Dynamic children from data

```rust
use iced::widget::{column, text};

column(
    items.iter().map(|item| text!("{}", item.name).into())
)
.spacing(4)
```

### Push conditionally

```rust
let mut col = column![text("Always here")].spacing(8);

if show_extra {
    col = col.push(text("Conditional"));
}
```

### Nested layout

```rust
column![
    row![text("Left"), text("Right")].spacing(16),
    row![text("Bottom-Left"), text("Bottom-Right")].spacing(16),
]
.spacing(12)
```

## Gotchas

- `Column` aligns children with `align_x` (horizontal); `Row` with `align_y` (vertical). There is no `align_y` on `Column` or `align_x` on `Row` -- children fill the cross-axis by default.
- `spacing` sets the gap **between** children, not around them. Use `padding` for outer space.
- `column![]` and `row![]` macros accept any `Into<Element>`, so string literals, `text()`, `button()`, etc. work directly.
- `from_vec` is useful when you have a pre-built `Vec<Element>`. The `column(iter)` free function is more ergonomic for iterators.
- `with_capacity` pre-allocates but does not add children -- combine with `.push()` or `.extend()`.
- `wrap()` converts a `Column` or `Row` into a flex-wrap layout where children flow to the next line/column when they exceed bounds.
- `max_width` exists on `Column` but not on `Row`. Use `width(Length::Fixed(n))` to constrain a `Row`.
- `clip(true)` clips overflowing children to the widget bounds. Off by default.

## See also

- `widget-stack.md` -- `Stack` for layered (z-axis) layout
- `length.md` -- `Length::Fill`, `Shrink`, `Fixed`, `FillPortion`
- `padding.md` -- `Padding` constructors
- `alignment.md` -- `Horizontal`, `Vertical`, `Alignment`
- `widget-layout-primitives.md` -- `center`, `space`, rules
