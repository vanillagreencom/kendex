# Length

> `iced::Length` · iced 0.14.0

Describes how a widget occupies space on a single axis. `Fill` takes all available space, `Shrink` uses intrinsic size, `Fixed(f32)` uses exact pixels, `FillPortion(u16)` distributes proportionally among siblings.

## API

```rust
pub enum Length {
    Fill,
    FillPortion(u16),
    Shrink,
    Fixed(f32),
}

impl Length {
    pub fn fill_factor(&self) -> u16;
    pub fn is_fill(&self) -> bool;
    pub fn fluid(&self) -> Length;
    pub fn enclose(self, other: Length) -> Length;
}
```

Trait impls: `From<f32>`, `From<u32>`, `From<Pixels>` all produce `Length::Fixed`. Derives `Copy`, `Clone`, `PartialEq`, `Debug`.

## Patterns

Fixed height:

```rust
use iced::widget::container;
use iced::Element;

fn view(state: &State) -> Element<'_, Message> {
    container("I am 300px tall!").height(300).into()
}
```

Fill available space:

```rust
container(content).width(Length::Fill).height(Length::Fill)
```

Ratio-based layout with `FillPortion`:

```rust
row![
    sidebar.width(Length::FillPortion(1)),
    main_content.width(Length::FillPortion(3)),
]
```

## Gotchas

- **Shrink is the default** for most widgets, but **containers inherit Fill
  from their children**. If you put a `Fill` child inside a container, the
  container will stretch to its parent on that axis — even if you wanted it
  to hug the child.
- `FillPortion(1)` is equivalent to `Fill`. If you want strict ratios, give
  all columns explicit `FillPortion` values — don't mix `Fill` and
  `FillPortion`.
- `Fixed(0.0)` is valid but rarely useful. Use `Shrink` to collapse to
  content.
- `From<u32>` yields a fixed length in **logical pixels**, not grid units.
  `container.height(50)` is 50px, not 50 rem.
- `fluid()` is the safe way to coerce an arbitrary `Length` into a
  Fill-or-Shrink value when you don't want explicit sizes to leak into a
  layout decision.
- `FillPortion` only distributes across siblings in the same axis of the same parent.

## See also

- `padding.md`
- `alignment.md`
- `advanced-layout.md`
- `widget-column-row.md`
