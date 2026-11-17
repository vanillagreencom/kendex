# Table

> `iced::widget::table` · iced 0.14.0

A grid-like visual representation of data distributed in columns and rows. Displays column headers and configurable cell padding/separators. Wrap it in a scrollable when needed.

## API

Iced 0.14.0 owns the declarations, bounds, feature gates and defaults: [widget/src/table.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/table.rs); [widget/src/helpers.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/helpers.rs).

## Patterns

### Basic data table

```rust
use iced::widget::{table, text};

struct User { id: u32, name: String, email: String }

let columns = vec![
    table::column("ID", |user: &User| text(user.id.to_string())).width(50),
    table::column("Name", |user: &User| text(&user.name)).width(150),
    table::column("Email", |user: &User| text(&user.email)).width(200),
];

table(columns, &users).padding(8).separator(1).into()
```

### Custom column alignment

```rust
table::column("Price", |item: &Item| text!("{:.2}", item.price))
    .width(100)
    .align_x(Horizontal::Right)
```

## Gotchas

- Row data type `T` must implement `Clone`.
- The table catalog styles separators. This release has no `Table::style` builder; style headers and cells through their child widgets.
- No built-in sorting -- sort your data before passing it to `table()`.
- Cell padding is uniform via `padding()`, or split with `padding_x()`/`padding_y()`.

## See also

- `widget-scrollable.md` -- wrap a table when it needs scrolling
- `catalog.md` -- the `Catalog` trait pattern
- `widgets.md` -- widget catalog
- `element.md` -- `Element` type used in column view closures
