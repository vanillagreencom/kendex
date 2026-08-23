# Animated Layout Transitions

Patterns for animating custom widgets between collapsed and expanded states: measured positions, keyed identity, geometry-driven travel, transition clipping.

**Read order**: `animation.md` → this guide → `guide-custom-widgets.md` → `advanced-tree.md` → `advanced-layout.md`.

**When to read**: before any animated expand/collapse, reorderable layered view, floating panel, toast, or variable-height animated list.

## Measured positions over estimated heights

Per-item height estimates (e.g. "each item is ~48px") are not a source of truth for final animated spacing.

**Acceptable**: rough travel budgets, fallback heuristics, initial layout before measurement.

**Not acceptable**: expanded layout spacing when child heights vary.

1. **Measure child layout.** Call `layout()` for each child; the node's `bounds().height` is the expanded height.
2. **Store measured expanded geometry alongside collapsed geometry in Tree state.**
3. **Interpolate from collapsed geometry to measured expanded geometry** — never to an estimate.

```rust
// In Tree state
struct ItemGeometry {
    collapsed_y: f32,
    expanded_y: f32,
    expanded_height: f32,
}

// During layout, measure each child's real expanded size
fn layout(&mut self, tree: &mut Tree, renderer: &Renderer, limits: &Limits) -> Node {
    let state = tree.state.downcast_mut::<ListState>();
    let mut y = 0.0;

    for (i, child) in self.children.iter_mut().enumerate() {
        let child_node = child.layout(&mut tree.children[i], renderer, &child_limits);
        let measured_height = child_node.bounds().height;

        state.items[i].expanded_y = y;
        state.items[i].expanded_height = measured_height;
        y += measured_height + self.spacing;
    }
    // ... assemble final Node with children
}
```

> **Warning**: special-case height adjustments ("add 24px when the item has an icon") mean the widget needs measured child layout, not more estimates.

## Collapsed-to-expanded transition pattern

### The pattern

1. **One stable item identity.** Each item has a unique key that survives reordering, insertion, and removal.
2. **One stable hover sensor.** The expand/collapse hitbox does not change size during the animation. See `guide-custom-widgets.md` § "Stable hover hit regions."
3. **Measured expanded positions.** Run child `layout()`, store sizes in Tree state.
4. **Collapsed positions from stack geometry** (overlap offset, stacking direction).
5. **Interpolate with a single `Animation<f32>` or `Animation<bool>`** (0.0 = collapsed, 1.0 = expanded).

```rust
// Tree state for the transition
#[derive(Default)]
struct CollapseState {
    expanded: Animation<bool>,
    items: Vec<ItemGeometry>,
}

struct ItemGeometry {
    collapsed_y: f32,
    expanded_y: f32,
    measured_height: f32,
}

impl ItemGeometry {
    fn y_at(&self, t: f32) -> f32 {
        self.collapsed_y + (self.expanded_y - self.collapsed_y) * t
    }
}

// In draw(), interpolate positions using the transition parameter
fn draw(&self, tree: &Tree, renderer: &mut Renderer, /* ... */) {
    let state = tree.state.downcast_ref::<CollapseState>();
    let now = /* current Instant */;
    let t = state.expanded.interpolate_with(
        |b| if *b { 1.0 } else { 0.0 }, now,
    );

    for (i, (child, child_tree)) in self.children.iter()
        .zip(tree.children.iter())
        .enumerate()
    {
        let y = state.items[i].y_at(t);
        renderer.with_translation(Vector::new(0.0, y), |renderer| {
            child.draw(child_tree, renderer, /* ... */);
        });
    }
}
```

### What to avoid

**Duplicated animated trees in a `stack`.** Do not crossfade a full collapsed tree and a full expanded tree. Both trees receive events, identity is duplicated in `diff()`, and the crossfade shows overlap artifacts.

```rust
// BAD: two full trees crossfading
stack![
    container(collapsed_list).opacity(1.0 - t),  // full tree with event handlers
    container(expanded_list).opacity(t),           // duplicate tree, duplicate events
]

// GOOD: one tree, interpolated positions
my_animated_list(items)
    .expanded(self.is_expanded)  // single source of truth
```

**Branch-swap.** Do not use `if expanded { expanded_view() } else { collapsed_view() }`: the view pops, the tree shape change resets persistent state, and it violates `../SKILL.md` § "Widget tree consistency".

```rust
// BAD: branch swap — pops, loses state
if self.expanded {
    expanded_list(items).into()
} else {
    collapsed_stack(items).into()
}

// GOOD: single widget, animated t parameter
animated_list(items).expanded(self.expanded)
```

**Expanded-height hitbox as hover source.** Do not use a `mouse_area` the size of the expanded content for collapse/expand hover: when collapsed it extends past visible content and empty space triggers expansion.

## Keyed identity in reordered and layered views

### The problem

Iterating `self.children[sorted_indices[i]]` against Tree children stored in insertion order mismatches Tree child `i` and visual child `i`. Symptoms: wrong content after reorder, stale subtree state (hover, animation phase) on the wrong item, a removed item resetting its neighbor.

### The rule

**The key→Tree-child-index association must not change with visual ordering, in any presentation mode.**

Options:
1. **Use `keyed::Column`** for list presentations — it diffs by key, not position. See `widget-lazy-keyed.md`.
2. **Maintain a stable key→index mapping** in Tree state. When reordering visually, reorder draw calls (not child indices).
3. **Use `Tree::diff_children_custom`** with key-aware reconciliation when items are added, removed, or reordered. See `advanced-tree.md`.

```rust
// GOOD: stable Tree child order, reordered draw calls
fn draw(&self, tree: &Tree, renderer: &mut Renderer, /* ... */) {
    let state = tree.state.downcast_ref::<MyState>();

    // Visual order may differ from Tree child order
    for &draw_index in &state.visual_order {
        let child = &self.children[draw_index];
        let child_tree = &tree.children[draw_index];
        child.draw(child_tree, renderer, /* ... */);
    }
}
```

### Testing guidance

- **Reorder with distinct content.** Give each item distinct icons, text, colors; after reorder each item must show its own content.
- **Remove and verify neighbors.** Remove item N; item N+1 must not inherit N's hover, animation phase, or expanded state.
- **Switch presentation modes.** Toggle list/layered; each item keeps identity, animation state, content.
- **Inspect Tree children count.** After removal, `tree.children.len()` must equal the item count.

## Geometry-driven entry and exit travel

Entry/exit travel distance for floating or sliding UI must derive from measured geometry, not a fixed pixel constant. A fixed distance clips tall items and leaves remnants of short ones.

### The rule

```rust
// GOOD: travel derived from measured height
let travel = item.measured_height + margin;
let offset_y = travel * (1.0 - t);  // t: 0→1 during entry

// BAD: fixed travel regardless of content
const SLIDE_DISTANCE: f32 = 60.0;
let offset_y = SLIDE_DISTANCE * (1.0 - t);  // clips tall items, wastes space on short ones
```

When size is unknown until layout, use the measured `layout::Node` bounds stored in Tree state.

### Applies to

Toasts, notification banners, popovers, sliding panels, bottom sheets, dropdown menus, snackbars.

## Transition height and clipping

Interpolated positions are not enough: a widget that always reports its expanded height leaves trailing content visible and unclipped when collapsed.

### The rule

During a transition, the reported layout size and clipping region must match the current animated state:

```rust
fn layout(&mut self, tree: &mut Tree, renderer: &Renderer, limits: &Limits) -> Node {
    let state = tree.state.downcast_mut::<CollapseState>();
    let now = Instant::now();
    let t = state.expanded.interpolate_with(
        |b| if *b { 1.0 } else { 0.0 }, now,
    );

    let collapsed_height = self.collapsed_height();
    let expanded_height = self.measure_expanded_height(tree, renderer, limits);
    let current_height = collapsed_height + (expanded_height - collapsed_height) * t;

    // Report current animated height to parent — not always-expanded
    Node::new(Size::new(limits.max().width, current_height))
}
```

In `draw()`, clip children to the current animated bounds:

```rust
fn draw(&self, tree: &Tree, renderer: &mut Renderer, /* ... */) {
    let state = tree.state.downcast_ref::<CollapseState>();
    let current_height = /* interpolated height from state */;

    let clip = Rectangle {
        x: layout.bounds().x,
        y: layout.bounds().y,
        width: layout.bounds().width,
        height: current_height,
    };

    renderer.with_layer(clip, |renderer| {
        // Draw children — only visible within clip bounds
        for (child, child_tree) in self.children.iter().zip(tree.children.iter()) {
            child.draw(child_tree, renderer, /* ... */);
        }
    });
}
```

### Diagnostic

If content is visible below where it should be during collapse:
1. Is `layout()` returning the expanded height unconditionally?
2. Is `draw()` clipping to the current animated bounds with `renderer.with_layer()`?
3. Is `shell.invalidate_layout()` being called each animation frame so `layout()` re-runs?

## Anti-patterns summary

| Anti-pattern | Problem | Fix |
|---|---|---|
| Duplicated animated trees in `stack` | Double events, identity confusion, overlap artifacts | Single tree, interpolated positions |
| Branch-swap (`if expanded { A } else { B }`) | No transition, tree shape change resets state | Single tree with animated `t` parameter |
| Estimated heights as final spacing | Drift with mixed content, repeated one-off fixes | Measured child layout |
| Hover sensor on animated bounds | Enter/exit thrash during animation | Stable outer hitbox (see `guide-custom-widgets.md`) |
| Fixed travel distance | Clip or remnant with variable-height items | Geometry-derived travel |
| Always-expanded layout height | Trailing content visible when collapsed | Animated layout height + `with_layer` clipping |
| Position-based child reordering | Stale subtrees, wrong content after reorder | Key-stable identity mapping |

## See also

- `animation.md` — animation rules, `Animation<T>`, redraw scheduling, redraw vs rebuild invariant
- `guide-custom-widgets.md` — Widget impl checklist, draw order, hover stability, opacity semantics
- `guide-animation-debugging.md` — debugging checklist for animation/render bugs
- `advanced-tree.md` — Tree state, Tag, `diff_children_custom`
- `advanced-layout.md` — `layout::Node`, `Limits`
- `widget-lazy-keyed.md` — `keyed::Column` for key-based diffing
- `examples/toast/src/main.rs` — animated overlay with lifecycle, entry/exit
- `examples/loading_spinners/src/circular.rs` — custom Widget with Tree-state animation loop
