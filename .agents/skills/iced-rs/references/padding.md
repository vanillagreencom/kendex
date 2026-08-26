# Padding

> `iced::Padding` · iced 0.14.0

Per-side box spacing. Accepts scalar (uniform), `[v, h]`, `[t, r, b, l]`, or a `Padding` struct via `impl Into<Padding>`.

## API

```rust
pub struct Padding {
    pub top: f32,
    pub right: f32,
    pub bottom: f32,
    pub left: f32,
}

impl Padding {
    pub const ZERO: Padding;

    pub const fn new(padding: f32) -> Padding;

    pub fn top(self, top: impl Into<Pixels>) -> Padding;
    pub fn right(self, right: impl Into<Pixels>) -> Padding;
    pub fn bottom(self, bottom: impl Into<Pixels>) -> Padding;
    pub fn left(self, left: impl Into<Pixels>) -> Padding;

    pub fn horizontal(self, horizontal: impl Into<Pixels>) -> Padding;
    pub fn vertical(self, vertical: impl Into<Pixels>) -> Padding;

    pub fn x(&self) -> f32;
    pub fn y(&self) -> f32;

    pub fn fit(&self, inner: Size, outer: Size) -> Padding;
}
```

- **`ZERO`** — The `Padding::ZERO` constant.
- **`new(f32)`** — Creates equal padding on all four sides.
- **`top(..)` / `right(..)` / `bottom(..)` / `left(..)`** — Builder methods
  that replace one side and return the modified `Padding`.
- **`horizontal(..)`** — Sets both `left` and `right`.
- **`vertical(..)`** — Sets both `top` and `bottom`.
- **`x()`** — Returns the total horizontal padding (`left + right`).
- **`y()`** — Returns the total vertical padding (`top + bottom`).
- **`fit(inner, outer)`** — Adjusts the padding so an inner size fits inside
  an outer size.

From impls: `From<f32>` (uniform), `From<[f32; 2]>` (`[v, h]`), `From<[f32; 4]>` (`[t, r, b, l]`).

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
container(content).padding([5, 10, 15, 20]) // t/r/b/l
container(content).padding(Padding::ZERO)  // no padding
```

## Gotchas

- **`Padding::from([v, h])` is vertical-first**, matching CSS shorthand.
  Don't confuse with `[top, left]`.
- `Padding::from([t, r, b, l])` is **clockwise from top**, matching CSS.
- `x()` and `y()` return **totals**, not averages — use them to compute
  available content area: `content_width = bounds.width - padding.x()`.
- Padding fields are `f32`, not `u16` — sub-pixel padding is allowed but
  can cause blurry borders. Keep them integer for crisp rendering.
- The builder methods (`top`, `right`, etc.) take `impl Into<Pixels>`, so
  you can pass either a scalar or a `Pixels` type.
- No `Padding::symmetric(v, h)` helper -- use `Padding::from([v, h])` or builder methods.

## See also

- `length.md`
- `alignment.md`
- `advanced-layout.md`
- `widget-container.md`
