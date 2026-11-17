# Float

> `iced::widget::float` · iced 0.14.0

Read when making one widget float over other widgets with translation or scaling. The pinned [Float source] owns its declarations, trait bounds, style types and transform behavior. The [helper source] owns `float(content)`.

## Usage

`Float::new(content)` and `float(content)` each accept one child. For a floating action button above main content, wrap the action in Float and compose it with the base in a parent. Float does not accept a separate base argument. For tooltip behavior, see [Tooltip](widget-tooltip.md).

Float delegates sizing and layout to its child. The parent still allocates the child's ordinary layout footprint; translating or scaling the overlay does not resize that allocation.

## Positioning

The `translate` closure receives the child's original, non-scaled bounds and the viewport bounds. Return a displacement, not an absolute position. Account for both rectangles' origins.

At scale 1, this places the child's right and bottom edges 16 units inside the viewport:

```rust
use iced::widget::float;
use iced::Vector;

float(content).translate(|bounds, viewport| {
    Vector::new(
        viewport.x + viewport.width - bounds.x - bounds.width - 16.0,
        viewport.y + viewport.height - bounds.y - bounds.height - 16.0,
    )
})
```

This formula uses unscaled edges. For a scaled child, account for its visible extent after scaling around its center. During overlay construction, Float passes child bounds with the overlay offset applied and adds that offset to the returned displacement. Other phases can evaluate the closure on layout bounds without that offset; do not depend on a single call or identical inputs across phases.

## Scaling

Float activates its transformed overlay when the scale is greater than 1 or the translation is nonzero. Otherwise it delegates ordinary rendering and descendant overlays to the child.

A scale of 0.5 alone does not shrink the child. A nonzero translation activates the transform, so a minimap can use:

```rust
use iced::widget::float;
use iced::Vector;

float(minimap_widget)
    .scale(0.5)
    .translate(|_, _| Vector::new(16.0, 16.0))
```

With floating active, scaling is centered on the child. Returning `Vector::ZERO` requests no movement, but a scale greater than 1 still activates centered enlargement.

## Styling

Use `Float::style` to supply a style closure for a custom shadow and its border radius. Consult `Style` and `Catalog` in the [Float source] for the complete style shape and theme contract. `Float::class` requires the `advanced` feature.

## See also

- [Stack](widget-stack.md)
- [Pin](widget-pin.md)
- [Tooltip](widget-tooltip.md)
- [Custom overlays](advanced-overlay.md)

[Float source]: https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/float.rs
[helper source]: https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/helpers.rs
