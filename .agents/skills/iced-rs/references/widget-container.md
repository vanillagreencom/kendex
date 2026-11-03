# Container

Read when padding, sizing, aligning or decorating a single child in Iced 0.14.0.

The [pinned implementation](https://raw.githubusercontent.com/iced-rs/iced/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/container.rs) owns `Container`, its sizing/alignment helpers, clipping, ID, style, catalog and defaults. The [widget helpers](https://raw.githubusercontent.com/iced-rs/iced/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/helpers.rs) own the constructor.

## Size and align

```rust
use iced::widget::container;

container("Centered content")
    .padding(10)
    .center(800)
    .style(container::rounded_box)
```

`center(length)` sets both width and height, then centers the child on both axes. `center_x` and `center_y` set only their corresponding dimension and alignment. Alignment needs space within the container's bounds; it does not create that space.

To fill the parent and center a padded child:

```rust
use iced::{alignment, Length};

container(content)
    .width(Length::Fill)
    .height(Length::Fill)
    .padding(16)
    .align_x(alignment::Horizontal::Center)
    .align_y(alignment::Vertical::Center)
```

Use `max_width` and `max_height` to bound the available size. See [Length](length.md) and [Padding](padding.md) for their input semantics.

## Style

A container's style closure receives only the theme. It has no interaction status. Use a built-in style such as `rounded_box`, or change a `Style`:

```rust
container(content)
    .padding(12)
    .style(|theme| container::Style {
        background: Some(theme.extended_palette().background.weak.color.into()),
        border: iced::border::rounded(4)
            .width(1)
            .color(theme.palette().primary),
        ..container::Style::default()
    })
```

`container::background(background)` takes a background value and returns a Style. It is not a theme callback. `text_color: None` inherits the incoming renderer text color; an explicit color overrides it. Both closure styling and `.class(...)` use the [Catalog contract](catalog.md); this container's class method does not require `advanced`.

## Clipping and operations

`clip(true)` narrows the viewport passed to the child's drawing when the container intersects the incoming viewport. Without clipping, the child receives the incoming viewport. This wrapper does not add scrolling; use [Scrollable](widget-scrollable.md) for that. Check the actual renderer and child when pixel clipping matters.

`.id(widget::Id)` identifies the bounds reported to `Operation::container`. The container then traverses its child. Assigning an ID does not itself make the container focusable or scrollable.

## Related references

- [Stack](widget-stack.md): overlapping children.
