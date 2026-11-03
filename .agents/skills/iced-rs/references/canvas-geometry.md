# Canvas geometry and cache

Read when reusing or splitting Iced 0.14.0 Canvas geometry. The pinned [geometry cache](https://github.com/iced-rs/iced/blob/0.14.0/graphics/src/geometry/cache.rs) owns cache identity, bounds comparison and renderer storage reuse. The [frame declaration](https://github.com/iced-rs/iced/blob/0.14.0/graphics/src/geometry/frame.rs) owns conversion and clipping.

## Invalidation

A cache retains one current geometry. Its draw closure runs when the cache is empty, explicitly cleared or called with different bounds. Mutating chart data does not clear it. Call `clear()` when data used by the drawing changes; the method accepts a shared reference.

Keep the closure free of application side effects: a cache hit skips it. `draw` uses a size-based rectangle; `draw_with_bounds` uses the complete supplied clipping rectangle. Position changes can therefore invalidate the latter even when size stays the same. Keep bounds stable when the intended drawing region is stable; investigate changing sub-pixel values before changing layout rounding.

## Layers

Use separate caches for content with independent invalidation. A chart can keep grid, data series and crosshair geometry separately, clearing the series for data changes and the crosshair for cursor changes. Return the geometry in the desired drawing order. `canvas.md` retains the text-layer exception.

Caches created with the same group may reuse internal renderer storage. Group caches likely to change together, but clear each affected cache; sharing a group does not itself invalidate the others.

`draw_with_bounds` provides explicit clipping bounds. Do not replace every cache call with it without checking whether position belongs in that cache's identity. Consuming a frame produces renderer-specific geometry; further drawing needs another frame.

There is no separate prewarm or cached-size inspection method in this cache declaration. Run the actual draw operation when populating it, and keep a separate owner for any application data needed to decide invalidation. No backend speed or native clipping result is established by this reference.

## Related references

- `canvas.md`
- `canvas-path.md`
- `shader.md`
