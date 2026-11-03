# Length

Read when choosing a widget's width or height in iced 0.14.0. The pinned [Length declaration](https://github.com/iced-rs/iced/blob/0.14.0/core/src/length.rs) owns variants, conversions and layout helpers.

## Sizing

Choose a strategy independently for each axis. `Shrink` asks for the least space, `Fixed` asks for a fixed logical size, and filling strategies share remaining space. Parent constraints still govern the resulting layout; see [custom layout](advanced-layout.md).

`Fill` has the same weight as `FillPortion(1)`. Mix it with explicit portions when that weight is intended. Portions describe remaining space among siblings on the same parent axis, not an unconditional ratio of their final dimensions.

Do not assume a universal widget default. For example, [Container::new](https://github.com/iced-rs/iced/blob/0.14.0/widget/src/container.rs) derives its initial width and height from the child's fluid size hint. A filling child can therefore make its container fill that axis.

## Patterns

Set a fixed logical height or fill the space the parent offers:

```rust
use iced::widget::container;
use iced::Length;

let fixed = container(content).height(300);
let filling = container(other_content)
    .width(Length::Fill)
    .height(Length::Fill);
```

Give siblings explicit weights when their intended remaining-space ratio should be visible:

```rust
iced::widget::row![
    sidebar.width(Length::FillPortion(1)),
    main_content.width(Length::FillPortion(3)),
]
```

Numeric conversions produce fixed lengths in [logical pixels](https://github.com/iced-rs/iced/blob/0.14.0/core/src/pixels.rs), not character or grid units. A fixed zero asks for zero space; `Shrink` asks the layout to use the content's least space.

For layout code that needs only filling versus shrinking behavior, `fluid()` removes explicit sizes and portion weights. `enclose()` lets a shrinking strategy adopt a filling child; other cases remain unchanged. Use the declaration's `fill_factor()` contract when implementing a layout engine.

Check tight constraints, padding and sibling intrinsic sizes in the consuming layout. This reference provides source semantics; it does not establish a native layout result.

See [padding](padding.md), [alignment](alignment.md) and [rows and columns](widget-column-row.md).
