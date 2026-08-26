# Svg

> `iced::widget::svg` · iced 0.14.0 · feature = `svg`

Displays a vector graphics image (SVG) that resizes smoothly without quality loss. Supports color filtering, rotation, and opacity.

## API

### `Svg` struct

```rust
pub struct Svg<'a, Theme = Theme>
where
    Theme: Catalog,
{ /* private fields */ }

impl<'a, Theme> Svg<'a, Theme>
where
    Theme: Catalog,
{
    pub fn new(handle: impl Into<Handle>) -> Self;
    pub fn from_path(path: impl Into<PathBuf>) -> Self;

    pub fn width(self, width: impl Into<Length>) -> Self;
    pub fn height(self, height: impl Into<Length>) -> Self;
    pub fn content_fit(self, content_fit: ContentFit) -> Self;
    pub fn rotation(self, rotation: impl Into<Rotation>) -> Self;
    pub fn opacity(self, opacity: impl Into<f32>) -> Self;

    pub fn style(
        self,
        style: impl Fn(&Theme, Status) -> Style + 'a,
    ) -> Self
    where
        <Theme as Catalog>::Class<'a>: From<Box<dyn Fn(&Theme, Status) -> Style + 'a>>;

    pub fn class(
        self,
        class: impl Into<<Theme as Catalog>::Class<'a>>,
    ) -> Self; // feature = "advanced"
}
```

### `Handle` enum

```rust
pub enum Handle {
    Path(PathBuf),
    Bytes(Bytes),
}

impl Handle {
    pub fn from_path(path: impl Into<PathBuf>) -> Handle;
    pub fn from_memory(bytes: impl Into<Bytes>) -> Handle;
}
```

### `Status` enum

```rust
pub enum Status {
    Idle,
    Hovered,
}
```

### `Style` struct

```rust
pub struct Style {
    pub color: Option<Color>,
}
```

### `Catalog` trait

```rust
pub trait Catalog {
    type Class<'a>;
    fn default<'a>() -> Self::Class<'a>;
    fn style(&self, class: &Self::Class<'_>, status: Status) -> Style;
}
```

### Functions

```rust
pub fn svg<'a, Theme>(handle: impl Into<Handle>) -> Svg<'a, Theme>
where
    Theme: Catalog + 'a;
```

### Type aliases

```rust
pub type StyleFn<'a, Theme> = Box<dyn Fn(&Theme, Status) -> Style + 'a>;
```

## Patterns

### Display from file path

```rust
use iced::widget::svg;

svg("icons/settings.svg").width(24).height(24)
```

### Tint with a color on hover

```rust
svg("icon.svg")
    .style(|_theme, status| svg::Style {
        color: match status {
            svg::Status::Hovered => Some(Color::from_rgb(0.2, 0.5, 1.0)),
            svg::Status::Idle => Some(Color::WHITE),
        },
    })
```

### Load from bytes

```rust
let svg_data = include_bytes!("../assets/logo.svg");
svg(svg::Handle::from_memory(svg_data.as_slice()))
```

### Rotated icon

```rust
use iced::Rotation;

svg("arrow.svg").rotation(Rotation::from_degrees(90.0))
```

## Gotchas

- Requires the `svg` crate feature.
- Complex SVGs can be expensive to render, especially when resized frequently. Cache the handle in state.
- `Style::color` applies as a color filter (tint) to the entire SVG. Set to `None` to display original colors.
- `content_fit` defaults to `ContentFit::Contain`.

## See also

- `widget-image.md` -- raster image display
- `canvas.md` -- custom drawing with paths
- `catalog.md` -- the `Catalog` trait pattern
- `guide-custom-widgets.md` -- SVG alpha caveat (tint alpha may diverge from container alpha)
- `widgets.md` -- widget catalog
