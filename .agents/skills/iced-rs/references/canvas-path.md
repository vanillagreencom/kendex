# Canvas paths

Read when constructing Iced 0.14.0 vector geometry. Enable `canvas`. The pinned [Path](https://github.com/iced-rs/iced/blob/0.14.0/graphics/src/geometry/path.rs), [Builder](https://github.com/iced-rs/iced/blob/0.14.0/graphics/src/geometry/path/builder.rs) and [border radius](https://github.com/iced-rs/iced/blob/0.14.0/core/src/border.rs) declarations own constructors and curve methods.

## Construction

Use convenience constructors for lines, rectangles, rounded rectangles and circles. Use `Path::new` when a closure needs to build a polyline or curves; it builds the resulting path after the closure returns. A separately created builder is consumed by `build`.

```rust
use iced::Point;
use iced::widget::canvas::Path;

let line = Path::new(|path| {
    path.move_to(Point::new(0.0, 100.0));
    for (x, y) in points.iter().copied() {
        path.line_to(Point::new(x, y));
    }
});
```

Paths are immutable once built. Rebuild changed geometry and reuse stable paths where appropriate; do not assume a clone has no cost. `examples/bezier_tool/src/main.rs` shows path construction in a Canvas program.

## Corners and closure

`arc_to(a, b, radius)` joins the current path toward a corner near `a` with a tangent arc toward `b`. Follow it with `line_to(b)` when the path must continue to that endpoint. It is not a substitute for drawing the complete next segment. Inspect the builder's degenerate cases when points coincide or the radius is zero.

Use `iced::border::Radius` for rounded corners. `Radius::new(value)` and numeric conversion set a uniform radius; its named corner setters support asymmetric radii. `Point` and `Size` come from the root crate, not Canvas re-exports.

Call `close()` when the stroke must join the final point to the subpath start. Check fill behavior separately; implicit fill closure does not establish the same stroke. Verify thin strokes at the application's scale and transform instead of assuming integer coordinates alone guarantee crisp output.

## Related references

- `canvas.md`
- `canvas-geometry.md`
- `advanced-renderer.md`
