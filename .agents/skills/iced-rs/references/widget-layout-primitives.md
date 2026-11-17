# Layout primitives

> `iced::widget::{center, space, rule}` · iced 0.14.0

Read when centering content, adding empty space or dividing sections. The pinned [helper source] owns `center` and `space()`. The [Space source] and [Rule source] own their builders, styling and layout contracts.

## Centering and spacing

`center(content)` fills the available width and height and centers its child, like `container(content).center_x(Fill).center_y(Fill)`.

`space()` and `Space::new()` start with no size. Set `.width(...)` and `.height(...)` for explicit spacing. `space::horizontal()` fills the available horizontal space; `space::vertical()` fills the available vertical space.

```rust
use iced::widget::{center, row, space, text};

center(row![text("Left"), space::horizontal(), text("Right")])
```

## Dividers

Use `rule::horizontal(height)` between sections and `rule::vertical(width)` between panels. The argument sets the cross-axis thickness; the rule fills its other axis.

```rust
use iced::widget::{column, rule, text};

column![text("Section 1"), rule::horizontal(1), text("Section 2")]
    .spacing(8)
```

For side-by-side panels, use `row![left_panel, rule::vertical(1), right_panel]`.

`Rule::style` accepts a theme closure. Use the source's `Style` and `Catalog` declarations for the complete shape and bounds. Set thickness in the constructor. `Rule::class` requires the `advanced` feature.

```rust
use iced::widget::rule;

rule::horizontal(2).style(|theme: &iced::Theme| rule::Style {
    color: theme.extended_palette().primary.base.color,
    radius: 1.0.into(),
    fill_mode: rule::FillMode::Full,
    snap: true,
})
```

`FillMode::Full` draws across the whole available length and is the built-in theme's default. Other fill modes shorten that length; consult the [Rule source] for their semantics.

## See also

- [Container](widget-container.md): explicit alignment and padding.
- [Length](length.md): `Fill` and `Shrink`.
- [Padding](padding.md).
- [Widget catalog](widgets.md).

[helper source]: https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/helpers.rs
[Space source]: https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/space.rs
[Rule source]: https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/rule.rs
