# Custom-widget rendering

Read when drawing custom-widget primitives in Iced 0.14.0. The pinned [Renderer, Quad and Style declarations](https://github.com/iced-rs/iced/blob/0.14.0/core/src/renderer.rs) own the core interface. Specialized [image rendering](https://github.com/iced-rs/iced/blob/0.14.0/core/src/image.rs) and `advanced-text.md` supply their own contracts.

## Quads and groups

Set a quad's bounds explicitly; the default has no visible area. Supply border, shadow and snapping for the intended appearance, then fill it with a color or gradient background. The background carries gradient information; `fill_quad` has no separate gradient-angle argument. The border lies inside the quad's bounds.

Use a layer to clip a group of child draws, and a translation or transformation to move their drawing coordinates. These affect recorded primitives; they do not change widget layout or input coordinates.

```rust
renderer.with_layer(layout.bounds(), |renderer| {
    // Draw the children within these clipping bounds.
});

renderer.with_translation(Vector::new(0.0, -scroll_y), |renderer| {
    // Draw content at the translated position.
});
```

Keep start/end layer and transformation calls balanced. The closure helpers pair them on normal return; they do not install an unwind cleanup guard. Reset belongs to the runtime's frame boundary, not a nested widget draw call.

Use a shared clipping boundary when it holds the required child bounds. The interface does not promise a render target or fixed GPU cost per layer. Check actual backend cost before adding layers for performance. For animated fractional positions, check pixel snapping in rendered output to avoid visible jitter.

## Images and text

Use the specialized renderer trait for image measurement and drawing. `load_image` can block when content is not loaded, so keep it out of frame drawing when that would stall the UI. `measure_image` may return no dimensions while the backend loads and relayouts; drawing can similarly wait for readiness. Handle unavailable content and allocation errors explicitly.

The core allocation API reports through a callback. A cached wgpu allocation can invoke it immediately; do not assume every callback is deferred or every allocation is GPU work. The bundled `iced_wgpu/src/image/cache.rs` owns that behavior.

Use `advanced-text.md` for paragraph/editor/raw text choices and clipping. Keep renderer types generic where the trait requires it; `Element` erases widget types, not the renderer's generic drawing methods. Native alpha, clipping and performance still need the target renderer's evidence. The SVG fade audit remains in `guide-custom-widgets.md`.

## Related references

- `advanced-widget.md`
- `advanced-text.md`
- `canvas.md`
- `guide-custom-widgets.md`
