# Custom-widget layout

Read when measuring or positioning an Iced 0.14.0 custom widget. The pinned [layout helpers and Layout](https://github.com/iced-rs/iced/blob/0.14.0/core/src/layout.rs), [Limits](https://github.com/iced-rs/iced/blob/0.14.0/core/src/layout/limits.rs), [Node](https://github.com/iced-rs/iced/blob/0.14.0/core/src/layout/node.rs) and [flex resolver](https://github.com/iced-rs/iced/blob/0.14.0/core/src/layout/flex.rs) own the exact interfaces.

## Constraints and positions

Limits carry minimum, maximum and compression constraints. A node records the measured size, local position and child nodes. A new node starts at the origin; align, move or translate it when the content needs an offset. A `Layout` adds ancestor offsets and exposes absolute bounds for drawing and hit testing.

Apply the intended width and height to limits before resolving intrinsic content size. Fixed values remain bounded by parent constraints. Shrink sets compression, so a fill child does not universally force a shrinking parent to fill. Inspect the current limits and flex resolver instead of applying a blanket fill-propagation rule.

```rust
let limits = Limits::new(Size::ZERO, Size::new(800.0, 600.0))
    .width(Length::Fill)
    .height(Length::Fixed(100.0));

let node = Node::new(Size::new(50.0, 50.0))
    .align(Alignment::Center, Alignment::Start, Size::new(100.0, 100.0))
    .move_to(Point::new(10.0, 10.0));
```

Moving to an explicit point replaces the previous position; translating adds an offset. Choose the operation for the intended coordinate change.

## Helpers and children

Use the existing atomic/sized helpers for leaf measurement, contained/padded/positioned helpers for one child, and flex resolution for ordered groups. Padding reduces child limits and expands the resulting parent node; let the helper own that adjustment instead of subtracting it twice.

Produce one child layout for each child the later methods traverse. `Layout::child(index)` panics outside that list. `children()` and `child()` take the layout by value, but the layout handle is `Copy`; traversal does not consume the underlying node. Use its bounds for hit testing rather than looking for cursor methods on `Layout`.

Check measured bounds and child identity together when debugging overlap, clipping or a stale animation. `guide-animated-layout.md` owns animated geometry; this reference supplies no native layout or version-to-version behavior result.

## Related references

- `advanced-widget.md`
- `length.md`
- `padding.md`
- `alignment.md`
