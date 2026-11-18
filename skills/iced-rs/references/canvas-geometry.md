# Canvas: Geometry & Cache

> `iced::widget::canvas::{Geometry, Cache}` · iced 0.14.0

`Geometry` is the opaque output of `Frame::into_geometry()`. `Cache` stores generated geometry so draw calls can reuse it. Requires the `canvas` feature.

Read when caching Canvas geometry or choosing what invalidates a drawing layer.

## API

Read the [Iced 0.14.0 declarations](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/graphics/src/geometry/cache.rs) for cache methods and the [frame declarations](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/graphics/src/geometry/frame.rs) for `Frame::into_geometry`.

## Patterns

### Single cache

```rust
struct Chart {
    lines: canvas::Cache,
}

impl<Message> canvas::Program<Message> for Chart {
    type State = ();

    fn draw(
        &self,
        _state: &(),
        renderer: &Renderer,
        _theme: &Theme,
        bounds: Rectangle,
        _cursor: mouse::Cursor,
    ) -> Vec<canvas::Geometry> {
        let lines = self.lines.draw(renderer, bounds.size(), |frame| {
            // draw the lines once
        });
        vec![lines]
    }
}

// When data changes:
self.lines.clear();
```

### Multi-layer chart

```rust
struct Chart {
    grid:      canvas::Cache,
    series:    canvas::Cache,
    crosshair: canvas::Cache,
}

fn draw(...) -> Vec<canvas::Geometry> {
    vec![
        self.grid.draw(renderer, size, |f| draw_grid(f)),
        self.series.draw(renderer, size, |f| draw_series(f, &self.data)),
        self.crosshair.draw(renderer, size, |f| draw_crosshair(f, self.cursor)),
    ]
}

// Invalidate only the layer that changed:
self.series.clear();      // on new data
self.crosshair.clear();   // on mouse move
```

### Group caches likely to change together

```rust
let group = canvas::Group::unique();
let cache_a = canvas::Cache::with_group(group);
let cache_b = canvas::Cache::with_group(group);
// The two caches can share internal renderer storage.
```

### `draw_with_bounds` to clip

```rust
self.content.draw_with_bounds(renderer, visible_region, |frame| {
    // anything drawn outside `visible_region` is clipped away
});
```

## Gotchas

- **Caches are not invalidated automatically.** If you change the data you draw from, you must call `cache.clear()` explicitly. Forgetting is the classic "why isn't my chart updating?" bug.
- The closure passed to `cache.draw(...)` is only called on the **first** call after a clear or size change. Avoid side effects inside the closure other than drawing — it may or may not run on any given frame.
- Cache identity is keyed on the *size passed to `draw`*, not the widget bounds. If your layout produces sub-pixel sizes, the cache might invalidate every frame. Round your bounds when stable.
- `draw_with_bounds` takes a clipping rectangle. Changing its origin or size causes the cache to draw again.
- A single `Cache` can only store **one** geometry. If you need multiple layers that invalidate independently, use multiple caches.
- `Cache::clear()` takes `&self`, not `&mut self`. You can clear from inside an immutable context (which is essential because `Program::draw` receives `&self`).
- There is no separate pre-warm method; a call to `draw` computes or retrieves the cached geometry.

## See also

- `canvas.md`
- `canvas-path.md`
- `shader.md`
