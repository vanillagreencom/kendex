# Table

> `iced::widget::table` · iced 0.14.0

A grid-like visual representation of data distributed in columns and rows. Displays tabular data with column headers, scrolling, and configurable cell padding/separators.

## API

### `Table` struct

```rust
pub struct Table<'a, Message, Theme = Theme, Renderer = Renderer<Renderer, Renderer>>
where
    Theme: Catalog,
    Renderer: Renderer,
{ /* private fields */ }

impl<'a, Message, Theme, Renderer> Table<'a, Message, Theme, Renderer>
where
    Theme: Catalog,
    Renderer: Renderer,
{
    pub fn new(
        columns: impl IntoIterator<Item = Column<'a, 'b, T, Message, Theme, Renderer>>,
        rows: impl IntoIterator<Item = T>,
    ) -> Table<'a, Message, Theme, Renderer>
    where
        T: Clone;

    pub fn width(self, width: impl Into<Length>) -> Self;
    pub fn padding(self, padding: impl Into<Pixels>) -> Self;
    pub fn padding_x(self, padding: impl Into<Pixels>) -> Self;
    pub fn padding_y(self, padding: impl Into<Pixels>) -> Self;
    pub fn separator(self, separator: impl Into<Pixels>) -> Self;
    pub fn separator_x(self, separator: impl Into<Pixels>) -> Self;
    pub fn separator_y(self, separator: impl Into<Pixels>) -> Self;

    pub fn style(self, style: impl Fn(&Theme) -> Style + 'a) -> Self
    where
        <Theme as Catalog>::Class<'a>: From<StyleFn<'a, Theme>>;

    pub fn class(self, class: impl Into<<Theme as Catalog>::Class<'a>>) -> Self;
}
```

### `Column` struct

```rust
pub struct Column<'a, 'b, T, Message, Theme = Theme, Renderer = Renderer<Renderer, Renderer>>
{ /* private fields */ }

impl<'a, 'b, T, Message, Theme, Renderer> Column<'a, 'b, T, Message, Theme, Renderer> {
    pub fn new(
        header: impl Into<Element<'a, Message, Theme, Renderer>>,
        view: impl Fn(&'b T) -> Element<'a, Message, Theme, Renderer> + 'a,
    ) -> Self;

    pub fn width(self, width: impl Into<Length>) -> Self;
    pub fn align_x(self, alignment: Horizontal) -> Self;
    pub fn align_y(self, alignment: Vertical) -> Self;
}
```

### `Style` struct

```rust
pub struct Style {
    pub header: container::Style,
    pub row: container::Style,
    pub separator: Option<Color>,
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
pub fn table<'a, 'b, T, Message, Theme, Renderer>(
    columns: impl IntoIterator<Item = Column<'a, 'b, T, Message, Theme, Renderer>>,
    rows: impl IntoIterator<Item = T>,
) -> Table<'a, Message, Theme, Renderer>
where
    T: Clone,
    Theme: Catalog,
    Renderer: Renderer;

pub fn column<'a, 'b, T, Message, Theme, Renderer>(
    header: impl Into<Element<'a, Message, Theme, Renderer>>,
    view: impl Fn(&'b T) -> Element<'a, Message, Theme, Renderer> + 'a,
) -> Column<'a, 'b, T, Message, Theme, Renderer>;

pub fn default(theme: &Theme) -> Style;
```

### Type aliases

```rust
pub type StyleFn<'a, Theme> = Box<dyn Fn(&Theme) -> Style + 'a>;
```

## Patterns

### Basic data table

```rust
use iced::widget::{table, text};

struct User { id: u32, name: String, email: String }

let columns = vec![
    table::column("ID", |user: &User| text(user.id).into()).width(50),
    table::column("Name", |user: &User| text(&user.name).into()).width(150),
    table::column("Email", |user: &User| text(&user.email).into()).width(200),
];

table(columns, &users).padding(8).separator(1).into()
```

### Custom column alignment

```rust
table::column("Price", |item: &Item| text!("{:.2}", item.price).into())
    .width(100)
    .align_x(Horizontal::Right)
```

### Styled table

```rust
table(columns, &rows)
    .style(|theme| table::Style {
        header: container::Style {
            background: Some(theme.extended_palette().background.strong.color.into()),
            ..Default::default()
        },
        row: container::Style::default(),
        separator: Some(theme.extended_palette().background.weak.color),
    })
```

## Gotchas

- Row data type `T` must implement `Clone`.
- Table does not have a `Catalog`-based `Status` enum (unlike button/scrollable) -- the style function takes only `&Theme`, not `(&Theme, Status)`.
- No built-in sorting -- sort your data before passing it to `table()`.
- Cell padding is uniform via `padding()`, or split with `padding_x()`/`padding_y()`.

## See also

- `widget-scrollable.md` -- tables scroll internally
- `catalog.md` -- the `Catalog` trait pattern
- `widgets.md` -- widget catalog
- `element.md` -- `Element` type used in column view closures
