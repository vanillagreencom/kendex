# Widget

> `iced::advanced::widget::Widget` · iced 0.14.0

The core trait for custom widgets. Requires `size`, `layout`, and `draw`; most widgets also override `tag`, `state`, `diff`, `update`, and `mouse_interaction`. Generic over `Message`, `Theme`, and `Renderer`.

## API

Full trait definition:

```rust
pub trait Widget<Message, Theme, Renderer>
where
    Renderer: Renderer,
{
    // Required methods
    fn size(&self) -> Size<Length>;
    fn layout(
        &mut self,
        tree: &mut Tree,
        renderer: &Renderer,
        limits: &Limits,
    ) -> Node;
    fn draw(
        &self,
        tree: &Tree,
        renderer: &mut Renderer,
        theme: &Theme,
        style: &Style,
        layout: Layout<'_>,
        cursor: Cursor,
        viewport: &Rectangle,
    );

    // Provided methods
    fn size_hint(&self) -> Size<Length> { ... }
    fn tag(&self) -> Tag { ... }
    fn state(&self) -> State { ... }
    fn children(&self) -> Vec<Tree> { ... }
    fn diff(&self, tree: &mut Tree) { ... }
    fn operate(
        &mut self,
        _tree: &mut Tree,
        _layout: Layout<'_>,
        _renderer: &Renderer,
        _operation: &mut dyn Operation,
    ) { ... }
    fn update(
        &mut self,
        _tree: &mut Tree,
        _event: &Event,
        _layout: Layout<'_>,
        _cursor: Cursor,
        _renderer: &Renderer,
        _clipboard: &mut dyn Clipboard,
        _shell: &mut Shell<'_, Message>,
        _viewport: &Rectangle,
    ) { ... }
    fn mouse_interaction(
        &self,
        _tree: &Tree,
        _layout: Layout<'_>,
        _cursor: Cursor,
        _viewport: &Rectangle,
        _renderer: &Renderer,
    ) -> Interaction { ... }
    fn overlay<'a>(
        &'a mut self,
        _tree: &'a mut Tree,
        _layout: Layout<'a>,
        _renderer: &Renderer,
        _viewport: &Rectangle,
        _translation: Vector,
    ) -> Option<Element<'a, Message, Theme, Renderer>> { ... }
}
```

### Required methods

- **`size(&self) -> Size<Length>`** — Returns the `Size` of the `Widget` in
  lengths (`Length::Fill`, `Shrink`, or `Fixed`).
- **`layout(&mut self, tree, renderer, limits) -> Node`** — Returns the
  `layout::Node` of the `Widget`. The runtime uses this node to compute the
  `Layout` of the user interface.
- **`draw(&self, tree, renderer, theme, style, layout, cursor, viewport)`** —
  Draws the `Widget` using the associated `Renderer`.

### Provided methods

- **`size_hint(&self) -> Size<Length>`** — A hint used by some containers to
  adjust sizing strategy during construction.
- **`tag(&self) -> Tag`** — Returns the `Tag` identifying the widget's state
  type. Default is `Tag::stateless()`.
- **`state(&self) -> State`** — Returns the initial `State` the widget should
  be associated with. Default is `State::None`.
- **`children(&self) -> Vec<Tree>`** — Returns the state `Tree` of the widget's
  children. Override for composite widgets.
- **`diff(&self, tree: &mut Tree)`** — Reconciles the widget with the provided
  `Tree` (typically forwards to `tree.diff_children(...)`).
- **`operate(...)`** — Applies a widget `Operation` (focus/scroll/etc.) to the
  widget.
- **`update(...)`** — Processes a runtime `Event`. Receives `&mut Tree`, the
  `Event`, computed `Layout`, `Cursor`, `Renderer`, `Clipboard`, `Shell`, and
  `viewport`. Default does nothing.
- **`mouse_interaction(...)`** — Returns the current `mouse::Interaction` (e.g.
  `Pointer`, `Grab`). Default is `Interaction::None`.
- **`overlay(...)`** — Returns an optional overlay `Element` to render above
  the normal widget layer (menus, tooltips, modals). Receives a
  `translation: Vector` representing accumulated parent translation (needed
  when a widget is inside a scrollable).

## Patterns

Lifecycle method stubs:

```rust
fn update(
    &mut self,
    _tree: &mut Tree,
    _event: &Event,
    _layout: Layout<'_>,
    _cursor: Cursor,
    _renderer: &Renderer,
    _clipboard: &mut dyn Clipboard,
    _shell: &mut Shell<'_, Message>,
    _viewport: &Rectangle,
) {}

fn mouse_interaction(
    &self,
    _tree: &Tree,
    _layout: Layout<'_>,
    _cursor: Cursor,
    _viewport: &Rectangle,
    _renderer: &Renderer,
) -> Interaction {
    Interaction::None
}

fn overlay<'a>(
    &'a mut self,
    _tree: &'a mut Tree,
    _layout: Layout<'a>,
    _renderer: &Renderer,
    _viewport: &Rectangle,
    _translation: Vector,
) -> Option<Element<'a, Message, Theme, Renderer>> {
    None
}
```

## Gotchas

- Requires the `advanced` crate feature.
- `layout()` takes `&mut self` -- widgets can cache layout state during layout.
- `draw()` takes `&self` -- no mutation during draw; use `Tree` state instead.
- If `tag()` is overridden but `state()` is not (or vice versa), `downcast_*` calls will panic.
- Composite widgets must override both `children()` and `diff()` or child state will not reconcile.

## See also

- `advanced-tree.md`
- `advanced-shell.md`
- `advanced-layout.md`
- `advanced-renderer.md`
- `guide-custom-widgets.md` — full checklist, draw order, hover stability, opacity
- `guide-animated-layout.md` — measured positions, collapsed/expanded transitions
- `guide-animation-debugging.md` — symptom→cause checklist
