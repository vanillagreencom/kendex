# Image

> `iced::widget::image` · iced 0.14.0 · feature = `image`

Read when displaying raster images or choosing their sizing, filtering, cropping or transforms. The pinned [widget source] owns `Image` and its builders. The [core image source] owns `Handle`, `FilterMethod` and the advanced renderer image. The [ContentFit source] owns fitting behavior.

## Image data

Use `image(path)` for a file, `image(image::Handle::from_bytes(bytes))` for encoded PNG/JPEG data, or `image(image::Handle::from_rgba(width, height, pixels))` for decoded RGBA pixels. RGBA data must contain `width * height * 4` bytes. Prefer these constructors to constructing `Handle` variants; each variant also carries an image ID.

Handles identify cached image data. The same path produces the same ID; separate `from_bytes` and `from_rgba` calls create new IDs. Keep or clone a handle when reusing its data.

## Sizing and fitting

Set the widget bounds with `.width(...)` and `.height(...)`. `.expand(true)` uses available space while preserving aspect ratio without adding blank space on a `Shrink` axis.

`ContentFit::Contain` preserves aspect ratio and fits the whole image inside the bounds. `Cover` fills the bounds and crops excess. `Fill` stretches to the bounds. `None` keeps the original size. `ScaleDown` behaves like `Contain` without enlarging a smaller image. `Contain` is the default.

```rust
use iced::widget::image;
use iced::ContentFit;

image("assets/logo.png")
    .width(200)
    .height(100)
    .content_fit(ContentFit::Cover)
```

## Filtering and transforms

`FilterMethod::Linear` uses bilinear interpolation and is the default. Use `Nearest` for pixel art:

```rust
use iced::widget::image;

image("sprite.png")
    .filter_method(image::FilterMethod::Nearest)
    .scale(4.0)
```

`.scale(...)` scales the drawn image around its center. `.rotation(iced::Radians::from(iced::Degrees(45.0)))` rotates it. `.opacity(0.7)` changes transparency; opacity zero still leaves the widget's layout allocation.

`.crop(iced::Rectangle { x: 0, y: 0, width: 32, height: 32 })` selects a region in source-image pixels before fitting or transforms. Coordinates are clamped to the image dimensions.

`.border_radius(...)` applies around the image's rectangular bounding box; it does not add a visible border. The widget passes pixel snapping to the renderer. For a custom renderer primitive, the advanced `iced::advanced::image::Image` has `.snap(true)`; that method is not a widget builder. Snapping and nearest filtering address different sources of blur.

## See also

- [SVG](widget-svg.md): vector graphics.
- [Canvas](canvas.md): `Frame::draw_image`.
- [Widget catalog](widgets.md).

[widget source]: https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/image.rs
[core image source]: https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/image.rs
[ContentFit source]: https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/content_fit.rs
