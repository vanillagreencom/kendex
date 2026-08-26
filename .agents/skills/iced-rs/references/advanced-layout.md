# Layout

> `iced::advanced::layout` · iced 0.14.0

Layout machinery for sizing and positioning widgets. Three central types: `Node` (computed bounds + children), `Limits` (min/max constraints), and `Layout<'a>` (absolute-position view passed to `draw`/`update`).

## API

### `layout::Node`

```rust
pub struct Node { /* private fields */ }

impl Node {
    pub const fn new(size: Size) -> Node;
    pub const fn with_children(size: Size, children: Vec<Node>) -> Node;
    pub fn container(child: Node, padding: Padding) -> Node;

    pub fn size(&self) -> Size;
    pub fn bounds(&self) -> Rectangle;
    pub fn children(&self) -> &[Node];

    pub fn align(self, align_x: Alignment, align_y: Alignment, space: Size) -> Node;
    pub fn align_mut(&mut self, align_x: Alignment, align_y: Alignment, space: Size);

    pub fn move_to(self, position: impl Into<Point>) -> Node;
    pub fn move_to_mut(&mut self, position: impl Into<Point>);

    pub fn translate(self, translation: impl Into<Vector>) -> Node;
    pub fn translate_mut(&mut self, translation: impl Into<Vector>);
}
```

- **`new(size)`** — Creates a leaf `Node`.
- **`with_children(size, children)`** — Leaf with children already laid out.
- **`container(child, padding)`** — Wraps a single child with padding.
- **`align(...)`** — Aligns the node within some `space` using the given x/y
  alignments.
- **`move_to(p)` / `translate(v)`** — Position/offset the node; `_mut`
  variants modify in place.

### `layout::Limits`

```rust
pub struct Limits { /* private fields */ }

impl Limits {
    pub fn new(min: Size, max: Size) -> Limits;
    pub fn with_compression(min: Size, max: Size, compress: Size<bool>) -> Limits;

    pub fn width(self, width: impl Into<Length>) -> Limits;
    pub fn height(self, height: impl Into<Length>) -> Limits;
    pub fn min_width(self, min_width: f32) -> Limits;
    pub fn max_width(self, max_width: f32) -> Limits;
    pub fn min_height(self, min_height: f32) -> Limits;
    pub fn max_height(self, max_height: f32) -> Limits;

    pub fn resolve(
        &self,
        width: impl Into<Length>,
        height: impl Into<Length>,
        intrinsic_size: Size,
    ) -> Size;
}
```

- **`new(min, max)`** — Creates new `Limits` with min/max sizes.
- **`width(...)` / `height(...)`** — Applies a length constraint to the limit
  chain.
- **`resolve(width, height, intrinsic_size)`** — Computes the resulting `Size`
  that fits the `Limits`, combining explicit length strategies with the
  widget's intrinsic size.

### `layout::Layout<'a>`

```rust
impl<'a> Layout<'a> {
    pub fn new(node: &'a Node) -> Layout<'a>;
    pub fn with_offset(offset: Vector, node: &'a Node) -> Layout<'a>;

    pub fn position(&self) -> Point;
    pub fn bounds(&self) -> Rectangle;

    pub fn children(self) -> impl DoubleEndedIterator + ExactSizeIterator;
    pub fn child(self, index: usize) -> Layout<'a>;
}
```

- **`position()`** — Absolute top-left `Point` of the laid-out node.
- **`bounds()`** — Absolute `Rectangle` describing position and size.
- **`children()`** — Double-ended iterator over the child `Layout`s.
- **`child(index)`** — Index directly into a child layout. Panics on
  out-of-bounds.

### Layout helper functions

```rust
pub fn sized(
    limits: &Limits,
    width: impl Into<Length>,
    height: impl Into<Length>,
    f: impl FnOnce(&Limits) -> Size,
) -> Node

pub fn padded(
    limits: &Limits,
    width: impl Into<Length>,
    height: impl Into<Length>,
    padding: impl Into<Padding>,
    layout: impl FnOnce(&Limits) -> Node,
) -> Node

pub fn flex::resolve<Message, Theme, Renderer>(
    axis: Axis,
    renderer: &Renderer,
    limits: &Limits,
    width: Length,
    height: Length,
    padding: Padding,
    spacing: f32,
    align_items: Alignment,
    items: &mut [Element<'_, Message, Theme, Renderer>],
    trees: &mut [Tree],
) -> Node
```

- **`sized`** — Produce a sized `Node` from a closure that returns the
  intrinsic size within the shrunk limits.
- **`padded`** — Produce a padded node, passing shrunk limits to `layout`.
- **`flex::resolve`** — Full flex layout used by `Row`/`Column` internals.

### Additional layout helper functions

```rust
/// Computes an atomic (leaf) Node fitting within Limits.
/// Use for widgets with no children.
pub fn atomic(
    limits: &Limits,
    width: impl Into<Length>,
    height: impl Into<Length>,
) -> Node

/// Computes a contained Node: applies width/height to limits,
/// then delegates to the closure for the inner layout.
pub fn contained(
    limits: &Limits,
    width: impl Into<Length>,
    height: impl Into<Length>,
    f: impl FnOnce(&Limits) -> Node,
) -> Node

/// Like `padded` but adds a custom positioning step after layout.
/// The `position` closure receives the laid-out Node and the
/// available Size, returning the final positioned Node.
pub fn positioned(
    limits: &Limits,
    width: impl Into<Length>,
    height: impl Into<Length>,
    padding: impl Into<Padding>,
    layout: impl FnOnce(&Limits) -> Node,
    position: impl FnOnce(Node, Size) -> Node,
) -> Node

/// Arranges two nodes side-by-side horizontally with spacing.
/// Each closure receives limits adjusted for the other's size.
pub fn next_to_each_other(
    limits: &Limits,
    spacing: f32,
    left: impl FnOnce(&Limits) -> Node,
    right: impl FnOnce(&Limits) -> Node,
) -> Node
```

- **`atomic`** — Simplest helper: resolves `Length` constraints into a
  leaf `Node`. Use for widgets that have no children (e.g., a colored
  rectangle, a rule).
- **`contained`** — Like `sized` but delegates inner layout to a closure
  that receives constrained `Limits`. Use when wrapping a single child.
- **`positioned`** — Extends `padded` with a final positioning step. Use
  when the child's position depends on the computed layout (e.g.,
  alignment within remaining space).
- **`next_to_each_other`** — Two-column layout helper. Lays out `left`
  first, then gives `right` the remaining space. Used internally by
  widgets that pair a label with a control.

## Patterns

Building a `Limits` constraint:

```rust
let limits = Limits::new(Size::new(0.0, 0.0), Size::new(800.0, 600.0))
    .width(Length::Fill)
    .height(Length::Fixed(100.0));
```

Manipulating a `Node`:

```rust
use iced::advanced::layout::Node;
use iced::{Alignment, Size, Point};

let mut node = Node::new(Size::new(50.0, 50.0));

// Align the node within a space
node = node.align(Alignment::Center, Alignment::Start, Size::new(100.0, 100.0));

// Move the node to a specific coordinate
node.move_to_mut(Point::new(10.0, 10.0));
```

## Gotchas

- `Node::new(size)` stores an intrinsic size; the *position* is 0,0 until you
  `move_to`/`translate`. If you forget, a widget will render at the parent's
  origin.
- Alignment and padding consume bounds: shrink the limits before handing them
  to a closure, or use the helper functions (`sized`, `padded`) which do it
  for you.
- `Layout::children()` and `Layout::child(i)` consume the `Layout` (they take
  `self`). Re-derive them from the parent when you need them again.
- `Length::Fill` is viral — any fill child in a shrink container will make the
  container fill its parent on that axis.
- `child(index)` panics if out of bounds — always mirror the number of
  children you produce in `layout()`.
- No `position_over` helper at the `Layout` level -- use `layout.bounds()` directly.

## See also

- `advanced-widget.md`
- `length.md`
- `padding.md`
- `alignment.md`
