# Alignment

> `iced::Alignment` · iced 0.14.0

Single-axis positioning enum: `Start`, `Center`, `End`. Direction-specific variants: `Horizontal` (`Left`/`Center`/`Right`) and `Vertical` (`Top`/`Center`/`Bottom`), convertible to/from `Alignment`.

Read when aligning row, column, text, or container content.

## API

Read the [Iced 0.14.0 declarations](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/alignment.rs) for signatures and available types.

## Patterns

```rust
// Row alignment along cross-axis (vertical) for items in a row
row![text("a"), button("b")]
    .align_y(Alignment::Center)

// Column alignment along cross-axis (horizontal) for items in a column
column![text("a"), button("b")]
    .align_x(Alignment::Center)

// Text alignment explicitly with Horizontal
text("hello").align_x(Horizontal::Right)

// Center content within a container with available room
container(inner)
    .align_x(Horizontal::Center)
    .align_y(Vertical::Center)
    .width(Length::Fill)
    .height(Length::Fill)
```

## Gotchas

- `Alignment::Start` / `End` are **direction-neutral**. For row cross-axis alignment they mean top/bottom; for column cross-axis alignment they mean left/right. The conversions do not inspect locale.
- For text, prefer the explicit `Horizontal` / `Vertical` enums — they are less ambiguous than `Alignment::Start` when discussing a specific axis.
- `Horizontal::Center` and `Vertical::Center` both convert from `Alignment::Center` — you never need a different "center" value for each axis.
- Centering a child inside a container requires free space on that axis, from a fixed or filled size. If the container shrinks to the child, there is no free space to centre within, and alignment has no visible effect.
- No `SpaceBetween`/`SpaceAround` variants. Use `.spacing(...)` for a fixed gap, or flexible space widgets to distribute spare space.

## See also

- `length.md`
- `padding.md`
- `widget-column-row.md`
- `widget-container.md`
