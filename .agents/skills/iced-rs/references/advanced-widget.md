# Custom widgets

Read when implementing an Iced 0.14.0 `Widget`. Enable the `advanced` feature for this public module. The pinned [Widget trait](https://github.com/iced-rs/iced/blob/0.14.0/core/src/widget.rs) owns method signatures and defaults. Read `guide-custom-widgets.md` before implementation and `guide-surface-selection.md` before choosing this primitive.

## Lifecycle

Implement size, layout and drawing. Size expresses the requested length strategy; layout measures it within limits and produces child nodes; drawing uses the resulting layout, renderer, theme, cursor and viewport.

In 0.14, layout receives mutable widget and tree references, and update receives a borrowed event. Draw receives shared widget/tree references. Mutate persistent interaction or animation state through the mutable lifecycle methods, then draw that state. `advanced-layout.md`, `advanced-tree.md` and `animation.md` own the detailed patterns.

Read `examples/custom_widget/src/main.rs` for a minimal circle widget. Read `examples/loading_spinners/src/circular.rs` for persistent animation state and event-driven redraws. Copy the pinned method shapes from those owners instead of adapting a 0.13 signature from memory.

## State and children

Stateful widgets keep their tag, initial state and downcast type consistent. A mismatched or stateless downcast panics. Composite widgets create their child trees and reconcile them; the default reconciliation clears children, so it is not a substitute for a composite's implementation.

Keep the child tree, layout and traversal order consistent across layout, draw, events and operations. Forward operations when descendants must remain focusable or scrollable. `advanced-operation.md` owns operation detail.

## Events and overlays

Use `update` for input, `mouse_interaction` for cursor feedback and Shell for messages, capture and invalidation. A size hint lets containers choose a sizing strategy during construction; it does not replace the measured layout.

An overlay borrows widget/tree state and receives parent translation. Forward descendant overlays with the same tree/layout/translation contract. `guide-custom-overlays.md` owns visibility, viewport and child-structure rules; `advanced-overlay.md` owns the low-level reading route. Native interaction and rendering must be checked in the target application.

## Related references

- `advanced-layout.md`
- `advanced-tree.md`
- `advanced-shell.md`
- `advanced-operation.md`
- `advanced-overlay.md`
- `guide-custom-widgets.md`
- `guide-custom-overlays.md`
