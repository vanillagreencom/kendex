# Canvas: Path & Builder

> `iced::widget::canvas::Path` · iced 0.14.0

Immutable 2D vector path for `Frame::fill` and `Frame::stroke`. Built via convenience constructors (`Path::line`, `Path::circle`, etc.) or `Path::new(|builder| ...)`. Requires the `canvas` feature.

Read when constructing a filled or stroked Canvas path.

## API

Read the [Iced 0.14.0 declarations](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/graphics/src/geometry/path.rs) for constructors, [the builder](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/graphics/src/geometry/path/builder.rs) for path operations, and [`Radius`](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/border.rs) for corner order.

## Patterns

### Convenience constructors

```rust
use iced::widget::canvas::Path;
use iced::{Point, Size, border::Radius};

// Create a line
let line = Path::line(Point::new(0.0, 0.0), Point::new(10.0, 10.0));

// Create a rectangle
let rect = Path::rectangle(Point::new(0.0, 0.0), Size::new(100.0, 50.0));

// Create a rounded rectangle
let rounded = Path::rounded_rectangle(
    Point::new(0.0, 0.0),
    Size::new(100.0, 50.0),
    Radius::from(10.0),
);

// Create a circle
let circle = Path::circle(Point::new(50.0, 50.0), 25.0);
```

### Build a polyline via closure

```rust
let line_series = Path::new(|p| {
    p.move_to(Point::new(0.0, 100.0));
    for (x, y) in points.iter().copied() {
        p.line_to(Point::new(x, y));
    }
});
```

### Smooth corner using `arc_to`

```rust
let corner = Path::new(|p| {
    p.move_to(Point::new(0.0, 0.0));
    p.line_to(Point::new(100.0, 0.0));
    p.arc_to(Point::new(100.0, 100.0), Point::new(0.0, 100.0), 20.0);
    p.line_to(Point::new(0.0, 100.0));
    p.close();
});
```

## Gotchas

- Build a new `Path` when its points change.
- `arc_to` connects to the first tangent point and draws a circular arc to the second tangent point. Use `line_to` afterwards to continue the path.
- Filled contours close implicitly in the tessellator. Call `close()` to add an explicit closing segment, including when you need a closed stroke.
- `Radius::from(f32)` creates uniform corners. For asymmetric: `Radius { top_left: tl, top_right: tr, bottom_right: br, bottom_left: bl }`.
- `Path::new(|p| ...)` implicitly builds -- no need to call `.build()` manually.
- Cloning a path copies its underlying point and verb buffers. Build stable paths once outside repeated drawing work.
- Align thin strokes with physical pixels when sharp edges matter. Account for display scaling and stroke width.

## See also

- `canvas.md`
- `canvas-geometry.md`
- `advanced-renderer.md`
