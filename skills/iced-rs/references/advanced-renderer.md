# Renderer

> `iced::advanced::Renderer` · iced 0.14.0

Drawing trait for widgets. Fill quads, clip layers, apply transformations, draw text and images. Not dyn-compatible -- widgets are monomorphised over a concrete `Renderer` type. Sub-traits: `text::Renderer`, `image::Renderer`.

Read when implementing or debugging renderer behavior in a custom widget or backend. Enable Iced’s `advanced` feature for the `iced::advanced` paths used here.

## Declarations

Pinned Iced 0.14.0 declarations, signatures, defaults and implementation:

- [core/src/renderer.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/renderer.rs).
- [core/src/image.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/image.rs).

## Patterns

Usage fragments below assume the surrounding widget implementation, imports and application message/state types.

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
    renderer.fill_quad(Quad { bounds, ..Quad::default() }, Color::BLACK);
    renderer.end_layer();
}
```

## Gotchas

- Balance `start_layer`/`end_layer` and transformation pairs. Prefer `with_*` helpers for ordinary control flow. These helpers call the closing method after the closure returns; they are not unwind guards.
- Use a layer at the clipping boundary and draw its children inside it. The core trait specifies clipping; allocation costs depend on the backend.
- `snap: true` only makes sense for integer-aligned rectangles. For sub-pixel-positioned geometry (e.g. animated panels mid-tween), leave it `false` to avoid wobble.
- `fill_quad` does not take a gradient angle — the `Background::Gradient` variant carries that information itself.
- The `Renderer` trait is **not dyn-compatible**; widgets that want to be object-safe must work around this (iced provides `Element` as the usual escape hatch).
- `reset(new_bounds)` is called by the runtime -- don't call it from inside widget `draw`.
- `measure_image` may return `None` while a backend loads an image and requests relayout. `draw_image` may similarly defer drawing and request redraw. Avoid `load_image` in drawing code when blocking would delay a frame.

## See also

- `advanced-widget.md`
- `advanced-text.md`
- `canvas.md`
- `shader.md`
- `guide-custom-widgets.md` — draw order, opacity/fade completeness, SVG alpha caveat
