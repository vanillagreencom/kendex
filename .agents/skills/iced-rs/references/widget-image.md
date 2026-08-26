# Image

> `iced::widget::image` · iced 0.14.0

Displays a raster image (PNG, JPEG, etc.) with configurable sizing, content fitting, filtering, rotation, opacity, scaling, cropping, and border radius.

## API

### `Image` struct

```rust
pub struct Image<Handle = image::Handle> { /* private fields */ }

impl<Handle> Image<Handle> {
    pub fn new(handle: impl Into<Handle>) -> Self;

    pub fn width(self, width: impl Into<Length>) -> Self;
    pub fn height(self, height: impl Into<Length>) -> Self;
    pub fn expand(self, expand: bool) -> Self;
    pub fn content_fit(self, content_fit: ContentFit) -> Self;
    pub fn filter_method(self, filter_method: FilterMethod) -> Self;
    pub fn rotation(self, rotation: impl Into<Rotation>) -> Self;
    pub fn opacity(self, opacity: impl Into<f32>) -> Self;
    pub fn scale(self, scale: impl Into<f32>) -> Self;
    pub fn crop(self, region: Rectangle<u32>) -> Self;
    pub fn border_radius(self, border_radius: impl Into<Radius>) -> Self;
}
```

### `Handle` enum

```rust
pub enum Handle {
    Path(PathBuf),
    Bytes(Bytes),
    Rgba {
        width: u32,
        height: u32,
        pixels: Bytes,
    },
}

impl Handle {
    pub fn from_path(path: impl Into<PathBuf>) -> Handle;
    pub fn from_bytes(bytes: impl Into<Bytes>) -> Handle;
    pub fn from_rgba(width: u32, height: u32, pixels: impl Into<Bytes>) -> Handle;
}
```

### `FilterMethod` enum

```rust
pub enum FilterMethod {
    Linear,   // Bilinear interpolation (smooth, default)
    Nearest,  // Nearest-neighbor (pixelated, sharp)
}
```

### `ContentFit` enum (re-exported)

```rust
pub enum ContentFit {
    Contain,    // Scale to fit, preserving aspect ratio (default)
    Cover,      // Scale to fill, preserving aspect ratio, cropping excess
    Fill,       // Stretch to fill exactly
    None,       // No scaling
    ScaleDown,  // Like Contain but never upscale
}
```

### Functions

```rust
pub fn image<Handle>(handle: impl Into<Handle>) -> Image<Handle>;
```

## Patterns

### Display from file path

```rust
use iced::widget::image;

image("assets/logo.png")
    .width(200)
    .height(100)
```

### Display from bytes (e.g., downloaded image)

```rust
use iced::widget::image;

image(image::Handle::from_bytes(raw_png_bytes))
    .content_fit(ContentFit::Cover)
```

### Pixel art with nearest-neighbor filtering

```rust
image("sprite.png")
    .filter_method(image::FilterMethod::Nearest)
    .scale(4.0)
```

### Rotated and semi-transparent

```rust
use iced::Rotation;

image("photo.jpg")
    .rotation(Rotation::from_degrees(45.0))
    .opacity(0.7)
```

### Crop a region

```rust
use iced::Rectangle;

image("spritesheet.png")
    .crop(Rectangle { x: 0, y: 0, width: 32, height: 32 })
```

## Gotchas

- The `image` feature must be enabled in your `iced` dependency.
- Images are cached by handle identity. Two `Handle::from_path("same.png")` calls share the same decoded texture.
- `FilterMethod::Nearest` + `snap(true)` (on the advanced `Image` type) prevents sub-pixel blurring for pixel art.
- `content_fit` defaults to `Contain` -- the image scales to fit without cropping. Use `Cover` for fill-and-crop behavior.
- `opacity(0.0)` makes the image fully transparent but it still participates in layout.
- `border_radius` currently applies only to the clip bounds, not a visible rounded border.

## See also

- `widget-svg.md` -- vector graphics (scales without quality loss)
- `canvas.md` -- drawing raster images on a canvas via `Frame::draw_image`
- `widgets.md` -- widget catalog
