# Length

> `iced::Length` · iced 0.14.0

Describes how a widget occupies space on a single axis. `Fill` takes all available space, `Shrink` uses intrinsic size, `Fixed(f32)` requests a size in logical pixels, `FillPortion(u16)` distributes proportionally among siblings.

Read when sizing widgets or distributing spare space among siblings.

## API

Read the [Iced 0.14.0 declarations](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/length.rs) for signatures and available types.

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

- Check each widget's default. **Containers inherit a child's fluid Fill/Shrink sizing**. If you put a `Fill` child inside a container, the container will stretch to its parent on that axis — even if you wanted it to hug the child.
- `FillPortion(1)` is equivalent to `Fill`. If you want strict ratios, give all columns explicit `FillPortion` values. `Fill` contributes one portion when mixed with them.
- `Fixed(0.0)` is valid but rarely useful. Use `Shrink` to collapse to content.
- `From<u32>` yields a fixed length in **logical pixels**, not grid units. `container.height(50)` is 50px, not 50 rem.
- Use `fluid()` to discard a fixed size or fill ratio when inheriting a child’s sizing behavior.
- `FillPortion` only distributes across siblings in the same axis of the same parent.

## See also

- `padding.md`
- `alignment.md`
- `advanced-layout.md`
- `widget-column-row.md`
