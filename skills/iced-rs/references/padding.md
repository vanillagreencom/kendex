# Padding

> `iced::Padding` · iced 0.14.0

Per-side box spacing. Accepts scalar (uniform), `[v, h]`, or a `Padding` struct via `impl Into<Padding>`.

Read when setting a widget’s inner spacing or calculating available content space.

## API

Read the [Iced 0.14.0 declarations](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/padding.rs) for signatures and available types.

## Patterns

```rust
// Uniform padding
let padding = Padding::from(20.0);

// Axis-specific padding [vertical, horizontal]
let padding = Padding::from([10.0, 20.0]);

// Direct construction
let padding = Padding {
    top: 5.0,
    right: 10.0,
    bottom: 5.0,
    left: 10.0,
};

// Builder style
let specific_padding = Padding::new(0.0)
    .top(10.0)
    .right(5.0)
    .bottom(10.0)
    .left(5.0);

// Combined sides
let vertical_padding = Padding::new(0.0).vertical(10.0);
let horizontal_padding = Padding::new(0.0).horizontal(5.0);

// Query totals
let total_x = specific_padding.x();
let total_y = specific_padding.y();
```

Typical widget use:

```rust
container(content).padding(20)             // uniform 20px
container(content).padding([10, 20])       // 10 top/bottom, 20 left/right
container(content).padding(Padding { top: 5.0, right: 10.0, bottom: 15.0, left: 20.0 })
container(content).padding(Padding::ZERO)  // no padding
```

## Gotchas

- **`Padding::from([v, h])` is vertical-first**, matching CSS shorthand. Don't confuse with `[top, left]`.
- Four-side array conversion is unavailable. Set named fields for four different sides.
- `x()` and `y()` return **totals**, not averages — use them to compute available content area: `content_width = bounds.width - padding.x()`.
- Padding is in logical pixels and accepts fractions. Check alignment after scaling to physical pixels if a border needs to be sharp.
- The builder methods (`top`, `right`, etc.) take `impl Into<Pixels>`, so you can pass either a scalar or a `Pixels` type.
- No `Padding::symmetric(v, h)` helper -- use `Padding::from([v, h])` or builder methods.

## See also

- `length.md`
- `alignment.md`
- `advanced-layout.md`
- `widget-container.md`
