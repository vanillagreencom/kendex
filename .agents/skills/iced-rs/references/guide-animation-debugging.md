# Animation and Rendering Debugging Checklist

Read when debugging a custom Iced widget after checking layout invalidation, redraw requests, and event capture.

## Master checklist

### 1. Is motion state in Tree state or stale widget fields?

A redraw request on its own repaints the existing tree. Fields computed in `view()` keep their previous values until the runtime rebuilds the view.

**Check**: is the animated value in `tree.state.downcast_mut::<State>()`, not a widget struct field?

### 2. Is redraw happening without rebuild?

Use messages or tasks to advance application state during a transition that depends on `App::update()`. The runtime rebuilds the view after processing the messages.

**Check**: does the animation advance via `RedrawRequested` in `Widget::update()`, or depend on `App::update()`?

### 3. Is draw order correct?

In custom `draw()`, iteration order is z-order: last drawn is on top. `stack` semantics do not apply inside manual draw loops.

**Check**: background drawn first, foreground last?

### 4. Is hover attached to animated bounds?

A hover sensor wrapping content that resizes during the hover-triggered animation thrashes enter/exit events.

**Check**: does the hover hitbox grow/shrink during the animation it triggers?

### 5. Are there duplicated animated branches?

Crossfading two full trees (collapsed and expanded) in a `stack` gives each branch separate state and handlers. Check which branches receive the event.

**Check**: does the tree contain two copies of the same logical content?

### 6. Is final spacing measured or guessed?

Estimated expanded heights give wrong spacing with mixed content.

**Check**: does layout use `child_node.bounds().height` from real `layout()` calls, or a constant?

### 7. Is current visible height/clipping correct during transitions?

A widget that reports expanded height while collapsing leaves content visible below the collapsed footprint.

**Check**: does `layout()` return the current animated height? Does `draw()` clip with `renderer.with_layer()`?

### 8. Are all child rendering paths participating in opacity?

A component that fades as one unit must fade every child: text, backgrounds, buttons, icons, canvas, SVGs, images, shader output.

**Check**: set opacity near zero — any visible remnant is a rendering path outside the fade contract.

### 9. Are keyed identities stable across reorder/removal?

Sorting child indices for display without updating Tree associations puts stale subtrees on the wrong items.

**Check**: after reorder, does each item show its own icon, text, state?

### 10. Are SVG/canvas/image paths obeying the same fade semantics?

SVG tint alpha, canvas colors, and image opacity may differ from text/container alpha across renderers.

**Check**: at near-zero opacity, does rendered alpha of SVG/canvas content match the expected value?

### 11. Is entry/exit travel derived from actual geometry?

Fixed-pixel travel clips or leaves remnants with variable-height content.

**Check**: is travel derived from the item's measured height, or a constant?

## Symptom quick lookup

| Symptom | Checks | Likely cause |
|---|---|---|
| Animation doesn't advance after first frame | 1, 2 | State in widget fields, not Tree; or redraw without rebuild |
| Layering looks inverted (background on top) | 3 | Wrong draw order in `draw()` |
| Hover flickers / thrashes during animation | 4 | Hover sensor on animated bounds |
| Double-click or double-event on animated items | 5 | Duplicated animated trees in `stack` |
| Spacing wrong for some items but not others | 6 | Estimated heights, not measured |
| Content visible below collapsed widget | 7 | Layout reports expanded height; no clipping |
| Near-transparent remnants after fade | 8, 10 | Partial fade contract; SVG/canvas not fading |
| Wrong content on items after reorder | 9 | Position-based identity, not key-based |
| Items clip during entry/exit animation | 11 | Fixed travel distance |
| Delayed visual response or change visible on second click | 1, 7 | Stale widget fields or layout. If the state transition changes geometry, check for `invalidate_layout()` at the transition. |

## See also

- `animation.md` — animation rules, redraw scheduling, redraw vs rebuild
- `guide-custom-widgets.md` — Widget impl checklist, draw order, hover stability, opacity
- `guide-animated-layout.md` — measured positions, collapsed/expanded transitions, keyed identity
- `advanced-tree.md` — Tree state persistence
- `advanced-shell.md` — Shell: `request_redraw`, `invalidate_layout`, `capture_event`
