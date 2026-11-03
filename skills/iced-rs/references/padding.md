# Padding

Read when adding space around content in iced 0.14.0. The pinned [Padding declaration](https://github.com/iced-rs/iced/blob/0.14.0/core/src/padding.rs) owns supported conversions, side builders and fitting behavior.

## Spacing

A scalar sets all sides. A two-element array sets vertical spacing first, then horizontal spacing. For unequal sides, construct `Padding` or use its side builders; this version does not define a four-element-array conversion.

```rust
use iced::Padding;

let uniform = Padding::from(20);
let axes = Padding::from([10, 20]);
let sides = Padding {
    top: 5.0,
    right: 10.0,
    bottom: 15.0,
    left: 20.0,
};
let adjusted = Padding::ZERO.vertical(10).right(5);
```

Side builders replace the selected sides and return the updated value. `vertical` sets top and bottom; `horizontal` sets left and right. Builders accept values convertible to `Pixels`. Fields use floating-point logical units; check visual alignment at the target scale instead of assuming integer values guarantee crisp borders.

## Widget and layout use

For a widget whose padding setter accepts `Into<Padding>`, pass the shorthand directly. [Container::padding](https://github.com/iced-rs/iced/blob/0.14.0/widget/src/container.rs) accepts these forms:

```rust
use iced::widget::container;

let padded = container(content).padding([10, 20]);
let asymmetric = container(other_content).padding(sides);
```

`x()` and `y()` return the total horizontal and vertical padding, not one side or an average. Use those totals when accounting for content space.

`fit(inner, outer)` reduces padding to the nonnegative available space. It allocates top before bottom and left before right. Tight bounds can therefore change the requested symmetry; inspect the consuming layout before relying on exact side spacing.

See [length](length.md), [alignment](alignment.md), [custom layout](advanced-layout.md) and [containers](widget-container.md).
