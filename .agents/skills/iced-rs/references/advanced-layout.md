# Layout

> `iced::advanced::layout` · iced 0.14.0

Layout machinery for sizing and positioning widgets. Three central types: `Node` (computed bounds + children), `Limits` (min/max constraints), and `Layout<'a>` (absolute-position view passed to `draw`/`update`).

Read when implementing or debugging layout behavior in a custom widget or backend. Enable Iced’s `advanced` feature for the `iced::advanced` paths used here.

## Declarations

Pinned Iced 0.14.0 declarations, signatures, defaults and implementation:

- [core/src/layout.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/layout.rs).
- [core/src/layout/node.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/layout/node.rs).
- [core/src/layout/limits.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/layout/limits.rs).
- [core/src/layout/flex.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/layout/flex.rs).

## Patterns

Usage fragments below assume the surrounding widget implementation, imports and application message/state types.

Use `atomic` for a leaf, `sized` for intrinsic dimensions, and `contained` for one child. `positioned` adds a final placement step to padded layout. `next_to_each_other` lays out the left child first and gives the right child the remaining width. `layout::flex::resolve` handles row/column children and their trees.

Building a `Limits` constraint:

```rust
let limits = Limits::new(Size::new(0.0, 0.0), Size::new(800.0, 600.0))
    .width(Length::Fill)
    .height(Length::Fixed(100.0));
```

Manipulating a `Node`:

```rust
use iced::advanced::layout::Node;
use iced::{Alignment, Size, Point};

let mut node = Node::new(Size::new(50.0, 50.0));

// Align the node within a space
node = node.align(Alignment::Center, Alignment::Start, Size::new(100.0, 100.0));

// Move the node to a specific coordinate
node.move_to_mut(Point::new(10.0, 10.0));
```

## Gotchas

- `Node::new(size)` stores an intrinsic size; the *position* is 0,0 until you `move_to`/`translate`. If you forget, a widget will render at the parent's origin.
- Apply width/height constraints before laying out content. Use `padded` to shrink child limits for padding; `sized` applies length constraints without adding padding.
- `Layout` is `Copy`. Its by-value `children()` and `child(i)` methods leave the original view reusable.
- `Limits::width(Length::Shrink)` and its height counterpart enable compression. `resolve` then uses the intrinsic size even for a fluid length. Do not assume a fill child forces a shrink parent to fill.
- `child(index)` panics if out of bounds — always mirror the number of children you produce in `layout()`.
- No `position_over` helper at the `Layout` level -- use `layout.bounds()` directly.

## See also

- `advanced-widget.md`
- `length.md`
- `padding.md`
- `alignment.md`
