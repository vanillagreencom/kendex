# Canvas: Path & Builder

> `iced::widget::canvas::Path` · iced 0.14.0

Immutable 2D vector path for `Frame::fill` and `Frame::stroke`. Built via convenience constructors (`Path::line`, `Path::circle`, etc.) or `Path::new(|builder| ...)`. Requires the `canvas` feature.

## API

### `Path` constructors

```rust
impl Path {
    pub fn new(f: impl FnOnce(&mut Builder)) -> Path;
    pub fn line(from: Point, to: Point) -> Path;
    pub fn rectangle(top_left: Point, size: Size) -> Path;
    pub fn rounded_rectangle(top_left: Point, size: Size, radius: Radius) -> Path;
    pub fn circle(center: Point, radius: f32) -> Path;
}
```

- **`new(f)`** — Build an arbitrary `Path` via a `Builder`.
- **`line(from, to)`** — A single line segment.
- **`rectangle(top_left, size)`** — An axis-aligned rectangle.
- **`rounded_rectangle(top_left, size, radius)`** — With rounded corners.
- **`circle(center, radius)`** — A circle.

### `Builder`

```rust
impl Builder {
    pub fn new() -> Builder;

    pub fn move_to(&mut self, point: Point);
    pub fn line_to(&mut self, point: Point);

    pub fn arc(&mut self, arc: Arc);
    pub fn arc_to(&mut self, a: Point, b: Point, radius: f32);

    pub fn bezier_curve_to(
        &mut self,
        control_a: Point,
        control_b: Point,
        to: Point,
    );
    pub fn quadratic_curve_to(&mut self, control: Point, to: Point);

    pub fn rectangle(&mut self, top_left: Point, size: Size);
    pub fn rounded_rectangle(
        &mut self,
        top_left: Point,
        size: Size,
        radius: Radius,
    );
    pub fn circle(&mut self, center: Point, radius: f32);

    pub fn close(&mut self);

    pub fn build(self) -> Path;
}
```

## Patterns

### Convenience constructors

```rust
use iced::widget::canvas::{Path, Point, Size, Radius};

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

- `Path` is **immutable once built** — to change it, build a new one.
  This is the opposite of the retained-mode approach some other canvas
  libraries take.
- `arc_to` is the HTML5-style "smooth corner" function — it does **not**
  actually draw a straight line to the first control point, it only
  smooths the corner. Follow it with a `line_to` to the next intended
  point.
- `close()` is optional but needed for a filled path to render as a
  closed region. An unclosed filled path is still filled (the fill rule
  assumes implicit closure), but stroke behaviour differs.
- `Radius::from(f32)` creates uniform corners. For asymmetric: `Radius::new(tl, tr, br, bl)`.
- `Path::new(|p| ...)` implicitly builds -- no need to call `.build()` manually.
- Paths are ref-counted and cheap to clone. Build once outside the draw closure for stable geometry.
- Sub-pixel coordinates produce blurry strokes -- snap to integers for crisp 1px lines.

## See also

- `canvas.md`
- `canvas-geometry.md`
- `advanced-renderer.md`
