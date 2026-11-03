# Column and Row

Read when arranging children vertically or horizontally, building a dynamic layout or wrapping children in Iced 0.14.0.

`Column` lays out children vertically. `Row` lays them out horizontally. The pinned [Column source](https://raw.githubusercontent.com/iced-rs/iced/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/column.rs) and [Row source](https://raw.githubusercontent.com/iced-rs/iced/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/row.rs) own their construction, sizing, alignment, clipping and wrapping. The [widget helpers](https://raw.githubusercontent.com/iced-rs/iced/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/helpers.rs) own the macros and iterator constructors.

## Build a layout

Use `column!` and `row!` for known children. The macros convert their entries to elements:

```rust
use iced::widget::{button, column, row, text};

column![
    text("Title").size(24),
    row![
        button("OK").on_press(Message::Ok),
        button("Cancel").on_press(Message::Cancel),
    ]
    .spacing(12)
    .align_y(iced::alignment::Vertical::Center),
]
.spacing(8)
.padding(16)
```

Use `column(iter)` or `row(iter)` for an iterator of elements:

```rust
column(items.iter().map(|item| text(&item.name).into()))
    .spacing(4)
```

`push` adds a child; `extend` adds an iterator. `with_capacity` reserves storage without adding children. A conditional child can be added to an existing layout:

```rust
let mut content = column![text("Always here")];
if show_extra {
    content = content.push(text("Conditional"));
}
```

`with_children`, the iterator helpers and `push` inspect child sizing hints. `from_vec` reuses an allocated vector without inspecting those hints. Set its width or height explicitly when its children need a fill strategy.

## Size and align

`spacing` adds gaps between children; `padding` adds space around the group. A regular Column uses `align_x` for horizontal alignment. A regular Row uses `align_y` for vertical alignment. Child [lengths](length.md) and available constraints determine filling; children do not automatically fill the cross axis. The [pinned flex resolver](https://raw.githubusercontent.com/iced-rs/iced/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/layout/flex.rs) owns allocation and cross-axis alignment.

Column provides `max_width`. Row has width sizing but no `max_width` method. A fixed width requests that width; use a [Container](widget-container.md) with `max_width` when the layout needs an upper bound. `clip(true)` narrows the viewport passed to drawing children that overflow; it is off by default.

## Wrap

`Row::wrap` starts another row when a child's width would exceed the available width. `Column::wrap` starts another column when a child's height would exceed the available height. Supply useful bounds on that axis. The wrapping types preserve alignment within each row or column and expose their own spacing and alignment methods; use their pinned declarations rather than assuming the regular widget's methods apply.

## Related references

- [Stack](widget-stack.md): overlapping children.
- [Padding](padding.md) and [alignment](alignment.md): spacing and alignment values.
- [Layout primitives](widget-layout-primitives.md): centering, space and rules.
