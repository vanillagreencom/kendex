# Canvas: Geometry & Cache

> `iced::widget::canvas::{Geometry, Cache}` · iced 0.14.0

`Geometry` is the opaque output of `Frame::into_geometry()`. `Cache` stores generated geometry to avoid recomputation -- the primary performance tool for canvas-heavy UIs. Requires the `canvas` feature.

## API

### Producing `Geometry` from a `Frame`

```rust
impl<Renderer> Frame<Renderer> {
    pub fn new(renderer: &Renderer, size: Size) -> Frame<Renderer>;
    pub fn into_geometry(self) -> <Renderer as Renderer>::Geometry;
}
```

- **`Frame::new(renderer, size)`** — Creates a frame with the given
  drawable size. Anything drawn outside `size` is clipped away. The frame
  is dropped when `into_geometry()` is called, consuming it.
- **`into_geometry()`** — Consumes the frame and returns the associated
  renderer's `Geometry` type. Each canvas `Program::draw` call returns a
  `Vec<Geometry>`, so you can produce multiple independent geometries in a
  single draw pass.

### `Cache`

See `canvas.md` for the full `Cache` API. Key methods: `new()`, `with_group(group)`, `clear()`, `draw(renderer, size, draw_fn)`, `draw_with_bounds(renderer, bounds, draw_fn)`.

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

### Group caches that invalidate together

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

- **Caches are not invalidated automatically.** If you change the data you
  draw from, you must call `cache.clear()` explicitly. Forgetting is the
  classic "why isn't my chart updating?" bug.
- The closure passed to `cache.draw(...)` is only called on the **first**
  call after a clear or size change. Avoid side effects inside the closure
  other than drawing — it may or may not run on any given frame.
- Cache identity is keyed on the *size passed to `draw`*, not the widget
  bounds. If your layout produces sub-pixel sizes, the cache might
  invalidate every frame. Round your bounds when stable.
- `draw_with_bounds` invalidates on `bounds` change, not just size change.
  Use it when you need clipping to an absolute rectangle (for scrollable
  viewports), not as a general "clip everything" helper.
- A single `Cache` can only store **one** geometry. If you need multiple
  layers that invalidate independently, use multiple caches.
- `Cache::clear()` takes `&self`, not `&mut self`. You can clear from
  inside an immutable context (which is essential because `Program::draw`
  receives `&self`).
- No API to inspect cached geometry size or pre-warm the cache.

## See also

- `canvas.md`
- `canvas-path.md`
- `shader.md`
