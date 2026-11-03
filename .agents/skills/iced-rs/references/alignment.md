# Alignment

Read when positioning widgets or text in Iced 0.14.0. The pinned [alignment declarations](https://github.com/iced-rs/iced/blob/0.14.0/core/src/alignment.rs) own the enums and conversions.

## Axes

`Alignment` names the start, center and end of an axis. Its conversions are fixed: start maps to left or top, and end maps to right or bottom. A row's cross-axis is vertical; a column's cross-axis is horizontal.

```rust
row![text("a"), button("b")].align_y(Alignment::Center)
column![text("a"), button("b")].align_x(Alignment::Center)
```

Use `Horizontal` and `Vertical` when an explicit axis makes the intent clearer. All three enums share the same center conversion. They do not provide space-between or space-around distribution; use layout spacing and space widgets for that task.

## Text and containers

Text has a separate [text::Alignment](https://github.com/iced-rs/iced/blob/0.14.0/core/src/text.rs) with direction-sensitive `Default` alignment. Converting widget `Alignment::Start` to text alignment produces `Left`; it does not select that default. Check text and layout behavior in both directions when supporting RTL content.

```rust
text("hello").align_x(Horizontal::Right)

container(inner)
    .width(Length::Fill)
    .height(Length::Fill)
    .align_x(Horizontal::Center)
    .align_y(Vertical::Center)
```

Alignment needs free space on the affected axis. `Fill` can provide it within the parent's limits. A container that shrinks exactly to its child has no spare area in which to center it.

## Related references

- `length.md`
- `padding.md`
- `widget-column-row.md`
- `widget-container.md`
