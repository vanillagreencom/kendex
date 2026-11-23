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

## Anchoring to a trigger

`translate` receives no other widget's bounds. A trigger's position reaches the closure only through the float's own bounds, so the float's place in the layout is its anchor.

- Put the float where the popover belongs in the layout: for a popover under a button, after the button in a `column` that holds only the button and the float. With the column's default spacing of 0, the float's `bounds` start at the button's lower edge.
- Push the float after the trigger only while the popover is open. A column matches child state by index, so a float inserted between the trigger and later children would shift each of them one index and reset their state, such as a `text_input`'s focus. In its own column, no child follows the float, and the column keeps its place among its siblings.
- Return a nonzero displacement. At scale 1, a zero displacement leaves the child drawn in place in the ordinary layout, not floating above the window.
- The float keeps its ordinary footprint (§ Usage), so the open popover moves the content after its column down.
- Inside a `scrollable`, the `viewport` argument is the scrollable's visible bounds, and Float clips its floating layer to that viewport.
- A `stack` lays out each layer within the stack's size, which is the base's size for the default `Shrink` stack, so a float in a layer over the button gets at most the button's size there.

```rust
use iced::widget::{button, column, float};
use iced::Vector;

let mut anchor = column![button("Options").on_press(Message::TogglePopover)];

if popover_open {
    anchor = anchor.push(float(popover).translate(|bounds, viewport| {
        let overflow = (bounds.x + bounds.width - viewport.x - viewport.width).max(0.0);
        Vector::new(-overflow, 4.0)
    }));
}
```

The closure keeps the popover inside the viewport's right edge and leaves a 4-unit gap under the button with the column's default spacing, which also keeps the displacement nonzero. The closure cannot flip the popover above the button, since it never receives the button's height. [Custom overlays](guide-custom-overlays.md) § Built-ins names when the anchored overlay template replaces Float.

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
