# Renderer

> `iced::advanced::Renderer` · iced 0.14.0

Drawing trait for widgets. Fill quads, clip layers, apply transformations, draw text and images. Not dyn-compatible -- widgets are monomorphised over a concrete `Renderer` type. Sub-traits: `text::Renderer`, `image::Renderer`.

## API

### `Renderer` trait (core)

```rust
pub trait Renderer {
    // Required methods
    fn start_layer(&mut self, bounds: Rectangle);
    fn end_layer(&mut self);

    fn start_transformation(&mut self, transformation: Transformation);
    fn end_transformation(&mut self);

    fn fill_quad(&mut self, quad: Quad, background: impl Into<Background>);

    fn reset(&mut self, new_bounds: Rectangle);

    fn allocate_image(
        &mut self,
        handle: &Handle,
        callback: impl FnOnce(Result<Allocation, Error>) + Send + 'static,
    );

    // Provided methods
    fn with_layer(&mut self, bounds: Rectangle, f: impl FnOnce(&mut Self));
    fn with_transformation(
        &mut self,
        transformation: Transformation,
        f: impl FnOnce(&mut Self),
    );
    fn with_translation(
        &mut self,
        translation: Vector,
        f: impl FnOnce(&mut Self),
    );
}
```

- **`start_layer(bounds)` / `end_layer()`** — Begin/end a clipped drawing
  layer. Everything drawn between the two calls is clipped to `bounds` and
  painted on a dedicated compositor layer (useful for masks, opacity, and
  scrollable clipping).
- **`start_transformation(t)` / `end_transformation()`** — Push/pop a 2D
  transformation (rotation, scale, translate) applied to subsequent draws.
- **`fill_quad(quad, background)`** — Fills a quadrilateral (rectangle with
  border + shadow + optional corner radius) with the supplied background.
  The workhorse for most widgets.
- **`reset(new_bounds)`** — Resets the renderer to start drawing in new
  bounds. Used by the runtime between frames.
- **`allocate_image(handle, callback)`** — Asynchronously allocates a GPU
  image for the given handle; the callback fires when the allocation is
  ready.
- **`with_layer(bounds, f)`** — RAII version of `start_layer/end_layer` —
  runs `f` inside the layer and ends it automatically.
- **`with_transformation(t, f)`** — RAII version of `start_transformation/
  end_transformation`.
- **`with_translation(v, f)`** — Convenience for translating by `v` only.
  Internally `with_transformation(Transformation::translate(v), f)`.

### `renderer::Quad` struct

```rust
pub struct Quad {
    pub bounds: Rectangle,
    pub border: Border,
    pub shadow: Shadow,
    pub snap: bool,
}
```

- **`bounds`** — The position and size of the quad.
- **`border`** — The `Border` (color + width + `Radius`). A `Border` has
  fields `color: Color`, `width: f32`, and `radius: Radius` (rounded corners).
- **`shadow`** — The drop `Shadow`.
- **`snap`** — Whether to snap the quad to the pixel grid. Set `true` for
  crisp 1px lines, false for sub-pixel placement.

`fill_quad` accepts any `impl Into<Background>`, where `Background` can be a
`Color` or a `Gradient`.

### `renderer::Style` struct

```rust
pub struct Style {
    pub text_color: Color,
}
```

The default style passed to `Widget::draw()` — currently just the inherited
text color. Widgets that render text should use `style.text_color` as their
default.

### `text::Renderer` sub-trait

See `advanced-text.md` for details. In short: associated types `Font`, `Paragraph`,
`Editor`; methods `fill_paragraph`, `fill_editor`, `fill_text` for drawing
text; and a bundle of icon constants (`CHECKMARK_ICON`, etc.).

### `image::Renderer` sub-trait

```rust
trait image::Renderer {
    type Handle: Clone;

    fn load_image(&self, handle: &Self::Handle) -> Result<Allocation, Error>;
    fn measure_image(&self, handle: &Self::Handle) -> Option<Size<u32>>;
    fn draw_image(
        &mut self,
        image: Image<Self::Handle>,
        bounds: Rectangle,
        clip_bounds: Rectangle,
    );
}
```

The raster image sub-trait. Not dyn-compatible. `load_image` may block if
the image is not already loaded. `measure_image` returns `None` and triggers
a background load if necessary.

## Patterns

### Filling a background rectangle

```rust
use iced::advanced::renderer::Quad;
use iced::{Background, Border, Color, Rectangle, Shadow};

fn draw(&self, ..., renderer: &mut Renderer, layout: Layout<'_>, ...) {
    renderer.fill_quad(
        Quad {
            bounds: layout.bounds(),
            border: Border {
                color: Color::BLACK,
                width: 1.0,
                radius: 4.0.into(),
            },
            shadow: Shadow::default(),
            snap: true,
        },
        Background::Color(Color::from_rgb(0.95, 0.95, 0.95)),
    );
}
```

### Clipping children inside a scrollable content area

```rust
renderer.with_layer(layout.bounds(), |renderer| {
    // anything drawn here is clipped to `layout.bounds()`
    for child in layout.children() {
        // draw children
    }
});
```

### Translating for a scroll offset

```rust
renderer.with_translation(Vector::new(0.0, -scroll_y), |renderer| {
    // children drawn shifted up by `scroll_y`
});
```

```rust
fn draw_custom_widget<R: Renderer>(renderer: &mut R, bounds: Rectangle) {
    renderer.start_layer(bounds);
    renderer.fill_quad(Quad::default(), Color::BLACK);
    renderer.end_layer();
}
```

## Gotchas

- `start_layer`/`end_layer` (and the transformation variants) **must be
  balanced**. Prefer the `with_*` RAII helpers whenever possible — they make
  imbalance impossible.
- Layers are not free. Each one allocates a scissor rect (or a dedicated
  render target, depending on backend). Don't wrap every widget in its own
  layer; push one layer at the scroll boundary and draw children unclipped
  inside.
- `snap: true` only makes sense for integer-aligned rectangles. For
  sub-pixel-positioned geometry (e.g. animated panels mid-tween), leave it
  `false` to avoid wobble.
- `fill_quad` does not take a gradient angle — the `Background::Gradient`
  variant carries that information itself.
- The `Renderer` trait is **not dyn-compatible**; widgets that want to be
  object-safe must work around this (iced provides `Element` as the usual
  escape hatch).
- `reset(new_bounds)` is called by the runtime -- don't call it from inside widget `draw`.
- `allocate_image` is asynchronous; skip drawing and request a redraw if `measure_image` returns `None`.

## See also

- `advanced-widget.md`
- `advanced-text.md`
- `canvas.md`
- `shader.md`
- `guide-custom-widgets.md` — draw order, opacity/fade completeness, SVG alpha caveat
