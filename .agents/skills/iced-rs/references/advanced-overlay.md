# Overlay

> `iced::advanced::overlay::Overlay` · iced 0.14.0

Trait for rendering on top of the normal widget tree (menus, tooltips, modals, popovers). Produced by `Widget::overlay()`; the runtime gives each overlay its own layout and draw pass above the main tree.

## API

### The `Overlay` trait

```rust
pub trait Overlay<Message, Theme, Renderer>
where
    Renderer: Renderer,
{
    // Required methods
    fn layout(&mut self, renderer: &Renderer, bounds: Size) -> Node;
    fn draw(
        &self,
        renderer: &mut Renderer,
        theme: &Theme,
        style: &Style,
        layout: Layout<'_>,
        cursor: Cursor,
    );

    // Provided methods
    fn operate(
        &mut self,
        _layout: Layout<'_>,
        _renderer: &Renderer,
        _operation: &mut dyn Operation,
    ) { ... }
    fn update(
        &mut self,
        _event: &Event,
        _layout: Layout<'_>,
        _cursor: Cursor,
        _renderer: &Renderer,
        _clipboard: &mut dyn Clipboard,
        _shell: &mut Shell<'_, Message>,
    ) { ... }
    fn mouse_interaction(
        &self,
        _layout: Layout<'_>,
        _cursor: Cursor,
        _renderer: &Renderer,
    ) -> Interaction { ... }
    fn overlay<'a>(
        &'a mut self,
        _layout: Layout<'a>,
        _renderer: &Renderer,
    ) -> Option<Element<'a, Message, Theme, Renderer>> { ... }
    fn index(&self) -> f32 { ... }
}
```

### Constructing overlays

Via `Widget::overlay`:

```rust
fn overlay<'a>(
    &'a mut self,
    tree: &'a mut Tree,
    layout: Layout<'a>,
    renderer: &Renderer,
    viewport: &Rectangle,
    translation: Vector,
) -> Option<Element<'a, Message, Theme, Renderer>>
```

Offset the overlay anchor by `translation` so it follows the widget through scrollables. `viewport` is the clip region -- use it to hide overlays when the anchor scrolls out of view.

### Overlay helpers

```rust
pub fn from_children<'a, Message, Theme, Renderer>(
    children: &'a mut [Element<'_, Message, Theme, Renderer>],
    tree: &'a mut Tree,
    layout: Layout<'a>,
    renderer: &Renderer,
    viewport: &Rectangle,
    translation: Vector,
) -> Option<Element<'a, Message, Theme, Renderer>>
where
    Renderer: Renderer,
```

Aggregates child overlays into a single optional overlay for composite widgets.

### `Group` (struct)

```rust
pub struct Group<'a, Message, Theme, Renderer> { /* ... */ }

impl<'a, Message, Theme, Renderer> Group<'a, Message, Theme, Renderer> {
    pub fn new() -> Self;
    pub fn with_children(
        children: Vec<Element<'a, Message, Theme, Renderer>>,
    ) -> Self;
    pub fn overlay(self) -> Element<'a, Message, Theme, Renderer>;
}
```

`Group` is an overlay container that displays multiple overlay children and
implements `Overlay` itself.

## Patterns

No standalone overlay examples in upstream docs. See `guide-custom-overlays.md` for full patterns.

## Gotchas

- `Overlay::draw` and `Overlay::update` do not take `viewport: &Rectangle` -- the overlay owns its rendering layer.
- Respect `translation` when computing anchor position or overlays will not follow through scrollables.
- Overlays are recreated each frame; open/closed state must live in the originating widget's `Tree` state.
- Returning `None` from `overlay()` stops rendering immediately -- no built-in fade-out.
- Default `index() = 1.0` -- override for deterministic ordering of multiple overlays.

## See also

- `advanced-widget.md`
- `advanced-tree.md`
- `guide-custom-overlays.md`
- `widget-tooltip.md`
