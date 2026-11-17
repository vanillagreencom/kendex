# Overlay

> `iced::advanced::overlay::Overlay` · iced 0.14.0

Trait for rendering on top of the normal widget tree (menus, tooltips, modals, popovers). Produced by `Widget::overlay()`; the runtime gives each overlay its own layout and draw pass above the main tree.

Read when implementing or debugging overlay behavior in a custom widget or backend. Enable Iced’s `advanced` feature for the `iced::advanced` paths used here.

## Declarations

Pinned Iced 0.14.0 declarations, signatures, defaults and implementation:

- [core/src/overlay.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/overlay.rs).
- [core/src/overlay/group.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/overlay/group.rs).
- [core/src/widget.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/widget.rs).

## Patterns

See `guide-custom-overlays.md` for construction patterns and the bundled `examples/toast/src/main.rs` for a complete overlay implementation. Offset the anchor by the `Widget::overlay` translation so it follows scrolling. Use the supplied viewport to decide whether the anchor is visible. Use `overlay::from_children` to collect child overlays; it returns `None` when none exist.

## Gotchas

- `Overlay::draw` and `Overlay::update` do not take `viewport: &Rectangle` -- the overlay owns its rendering layer.
- Respect `translation` when computing anchor position or overlays will not follow through scrollables.
- An overlay value borrows widget state when the runtime requests it. Keep persistent open/closed state in the originating widget’s `Tree` or application state.
- Returning `None` from `overlay()` stops rendering immediately -- no built-in fade-out.
- Higher `index()` values render above lower ones. Override the index when several overlays need explicit ordering.

## See also

- `advanced-widget.md`
- `advanced-tree.md`
- `guide-custom-overlays.md`
- `widget-tooltip.md`
