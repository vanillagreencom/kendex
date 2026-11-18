# Widget

> `iced::advanced::widget::Widget` · iced 0.14.0

The core trait for custom widgets. Requires `size`, `layout`, and `draw`; most widgets also override `tag`, `state`, `diff`, `update`, and `mouse_interaction`. Generic over `Message`, `Theme`, and `Renderer`.

Read when implementing or debugging widget behavior in a custom widget or backend. Enable Iced’s `advanced` feature for the `iced::advanced` paths used here.

## Declarations

Pinned Iced 0.14.0 declarations, signatures, defaults and implementation:

- [core/src/widget.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/widget.rs).

## Patterns

Usage fragments below assume the surrounding widget implementation, imports and application message/state types.

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
- `draw()` receives shared widget and tree references. Change persistent tree state in `update()` or `layout()` before drawing.
- Keep `tag()` and `state()` consistent with every `downcast_*` call. A downcast panics if state is absent or has another concrete type.
- Composite widgets must override both `children()` and `diff()` or child state will not reconcile.

## See also

- `advanced-tree.md`
- `advanced-shell.md`
- `advanced-layout.md`
- `advanced-renderer.md`
- `guide-custom-widgets.md` — full checklist, draw order, hover stability, opacity
- `guide-animated-layout.md` — measured positions, collapsed/expanded transitions
- `guide-animation-debugging.md` — symptom→cause checklist
