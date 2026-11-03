# Canvas

Read when implementing interactive 2D drawing in Iced 0.14.0. Enable the `canvas` feature. The pinned [Canvas widget](https://github.com/iced-rs/iced/blob/0.14.0/widget/src/canvas.rs), [Program trait](https://github.com/iced-rs/iced/blob/0.14.0/widget/src/canvas/program.rs) and [Frame](https://github.com/iced-rs/iced/blob/0.14.0/graphics/src/geometry/frame.rs) own the API.

## Program and geometry

Implement `Program::draw` to produce geometry. Its persistent `State` is separate from the program's configuration. Update receives a borrowed event and may mutate that state, returning an optional `Action` to publish, capture or request a redraw. Use `mouse_interaction` for the system cursor, checking bounds when the interaction should apply only inside the Canvas.

Create a frame for the drawing area, issue fill/stroke/text or image operations, then consume it with `into_geometry`. Set the Canvas width and height explicitly for the surrounding layout instead of assuming a shrink default.

Geometry is drawn in returned order. Split independent chart layers when they need different cache invalidation, as `canvas-geometry.md` describes. Frame text has an additional source-declared constraint: it renders above Canvas geometry layers, so do not infer arbitrary text z-order from the vector order alone.

## Coordinates and transforms

Use local frame coordinates for geometry and the supplied bounds/cursor for interaction. `Frame::new` clips geometry to its dimensions; use explicit bounds or clip regions when needed. The declaration owns the exact clipping interfaces.

Translate, rotate and scale the current frame transform. Use `with_save` to isolate a group of transforms; it pushes, calls the closure and pops on normal return. This is not an unwind-cleanup guarantee. Manual push/pop calls must stay paired so later drawing does not inherit an unintended transform.

Use the rectangle drawing operation when drawing a rectangle directly. A backend performance claim needs a measurement; the interface alone does not prove it faster than a path.

## Examples

Read `examples/bezier_tool/src/main.rs` for paths and interaction, `examples/clock/src/main.rs` for Canvas drawing, or `examples/solar_system/src/main.rs` for frame-driven animation and transforms. Clear retained geometry when its data changes. `animation.md` owns redraw and invalidation rules.

## Related references

- `canvas-path.md`
- `canvas-geometry.md`
- `shader.md`
- `guide-surface-selection.md`
