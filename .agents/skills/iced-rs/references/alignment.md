# Alignment

> `iced::Alignment` · iced 0.14.0

Single-axis positioning enum: `Start`, `Center`, `End`. Direction-specific variants: `Horizontal` (`Left`/`Center`/`Right`) and `Vertical` (`Top`/`Center`/`Bottom`), convertible to/from `Alignment`.

## API

### `Alignment` enum

```rust
pub enum Alignment {
    Start,
    Center,
    End,
}
```

### `Horizontal` enum

```rust
pub enum Horizontal {
    Left,
    Center,
    Right,
}
```

### `Vertical` enum

```rust
pub enum Vertical {
    Top,
    Center,
    Bottom,
}
```

### Conversions

`From`/`Into` between all three types: `Start`=`Left`=`Top`, `Center`=`Center`, `End`=`Right`=`Bottom`. All derive `Clone`, `Copy`, `Debug`, `PartialEq`, `Eq`, `Hash`.

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

// Center a container within an outer container
container(inner)
    .align_x(Horizontal::Center)
    .align_y(Vertical::Center)
    .width(Length::Fill)
    .height(Length::Fill)
```


## Gotchas

- `Alignment::Start` / `End` are **direction-neutral**. On a row they mean
  left/right; on a column they mean top/bottom. In RTL locales, "start" and
  "end" may flip — iced does not currently document an explicit
  direction-aware mode, so test layouts in both directions if you support
  RTL.
- For text, prefer the explicit `Horizontal` / `Vertical` enums — they are
  less ambiguous than `Alignment::Start` when discussing a specific axis.
- `Horizontal::Center` and `Vertical::Center` both convert from
  `Alignment::Center` — you never need a different "center" value for each
  axis.
- Centering a child inside a container requires the container to have a
  `Fill` size on that axis. If the container shrinks to the child, there is
  no free space to centre within, and alignment has no visible effect.
- No `SpaceBetween`/`SpaceAround` variants. Use `row!`/`column!` with `.spacing(...)`.

## See also

- `length.md`
- `padding.md`
- `widget-column-row.md`
- `widget-container.md`
