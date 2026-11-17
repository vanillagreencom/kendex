# Svg

Read when displaying, tinting or rotating an SVG with Iced 0.14.0. Enable the `svg` feature on `iced`.

Use the built-in `iced::widget::svg` for vector images that resize without losing quality. The [widget source] owns constructors, sizing, fitting defaults and styling signatures. The [handle source] owns SVG data loading; the [helper source] defines `svg(handle)` as a call to `Svg::new(handle)`.

## Loading and sizing

Pass a file path to `svg(...)`, or construct a handle with `svg::Handle::from_path`. `Svg::from_path` is also available. Set the widget's width and height, then choose a [ContentFit] strategy for the image within those bounds.

```rust
use iced::widget::{svg, Svg};
use iced::ContentFit;

fn icon() -> Svg<'static> {
    svg("icons/settings.svg")
        .width(24)
        .height(24)
        .content_fit(ContentFit::Contain)
}
```

`Handle` is an opaque struct. `Handle::from_memory` accepts SVG bytes or gzip-compressed SVG data. Use a static byte slice for an embedded asset, or owned bytes for data loaded at runtime.

```rust
use iced::widget::{svg, Svg};

fn logo() -> Svg<'static> {
    let bytes = include_bytes!("../assets/logo.svg");
    svg(svg::Handle::from_memory(bytes.as_slice()))
}
```

The paths in these examples name assets in the consuming application. Keep a reusable handle in application state when displaying the same data repeatedly. Resizing complex SVGs can still have a considerable rendering cost.

## Tint and opacity

`.style(...)` receives the theme and the SVG's idle or hovered status. Return `svg::Style` with `color: Some(...)` to tint the whole image, replacing its intrinsic colors. Use `color: None` to retain them. The bundled [SVG example](../examples/svg/src/main.rs) switches between a tint and the original colors.

```rust
use iced::widget::{svg, Svg};
use iced::Color;

fn hover_icon() -> Svg<'static> {
    svg("icon.svg").style(|_theme, status| svg::Style {
        color: match status {
            svg::Status::Hovered => Some(Color::from_rgb(0.2, 0.5, 1.0)),
            svg::Status::Idle => Some(Color::WHITE),
        },
    })
}
```

Use `.opacity(...)` for transparency, with values from `0.0` to `1.0`. Before relying on a tint for a fade, follow the [SVG alpha checks](guide-custom-widgets.md#svg-alpha-caveat).

For a custom theme, implement `svg::Catalog`. Its class selects a style for the current status. The `.style(...)` closure requires a class that can be built from `svg::StyleFn`; `.class(...)` requires the `advanced` feature. See the [widget source] and [catalog guide](catalog.md) for those contracts.

## Rotation

Convert degrees to `Radians` before passing the angle to `.rotation(...)`. The [angle source] defines the conversion; the [rotation source] defines how rotation affects layout. Converting `Radians` into `Rotation` uses floating rotation, which keeps the unrotated layout size. Use `Rotation::Solid` when layout must fit the rotated content.

```rust
use iced::widget::{svg, Svg};
use iced::{Degrees, Radians};

fn arrow() -> Svg<'static> {
    svg("arrow.svg").rotation(Radians::from(Degrees(90.0)))
}
```

## Related references

- [Image](widget-image.md): raster images.
- [Canvas](canvas.md): custom drawing with paths.
- [Widgets](widgets.md): widget selection.

[widget source]: https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/svg.rs
[handle source]: https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/svg.rs
[helper source]: https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/helpers.rs
[ContentFit]: https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/content_fit.rs
[angle source]: https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/angle.rs
[rotation source]: https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/rotation.rs
