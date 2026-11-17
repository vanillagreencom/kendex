# Tree

> `iced::advanced::widget::tree` · iced 0.14.0

Persistent state backbone for widgets. Each widget gets a `Tree` node holding a `Tag`, a `State` (type-erased `Box<dyn Any>`), and child trees. Wired via `Widget::tag`, `Widget::state`, `Widget::children`, and `Widget::diff`.

Read when implementing or debugging tree behavior in a custom widget or backend. Enable Iced’s `advanced` feature for the `iced::advanced` paths used here.

## Declarations

Pinned Iced 0.14.0 declarations, signatures, defaults and implementation:

- [core/src/widget/tree.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/widget/tree.rs).
- [core/src/widget.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/widget.rs).

## Patterns

Declaring persistent state:

```rust
struct MyWidgetState {
    hovered_index: Option<usize>,
    animation_time: f32,
}

impl<Message, Theme, Renderer> Widget<Message, Theme, Renderer> for MyWidget
where
    Renderer: iced::advanced::Renderer,
{
    fn tag(&self) -> Tag {
        Tag::of::<MyWidgetState>()
    }

    fn state(&self) -> State {
        State::new(MyWidgetState {
            hovered_index: None,
            animation_time: 0.0,
        })
    }

    // ...

    fn update(
        &mut self,
        tree: &mut Tree,
        event: &Event,
        layout: Layout<'_>,
        cursor: Cursor,
        renderer: &Renderer,
        clipboard: &mut dyn Clipboard,
        shell: &mut Shell<'_, Message>,
        viewport: &Rectangle,
    ) {
        let state = tree.state.downcast_mut::<MyWidgetState>();
        // mutate state...
    }
}
```

Reconciling composite widget children:

```rust
fn children(&self) -> Vec<Tree> {
    self.children.iter().map(Tree::new).collect()
}

fn diff(&self, tree: &mut Tree) {
    tree.diff_children(&self.children);
}
```

## Gotchas

- `tag()` and `state()` must agree. If `tag()` returns `Tag::of::<Foo>()` but `state()` returns `State::None`, `downcast_ref::<Foo>()` will panic.
- `downcast_ref` / `downcast_mut` panic on mismatch — always use the same concrete `T` that `state()` produced.
- Changing the state type `T` in a live widget will wipe the state (because the `Tag` no longer matches), resetting any persistent state such as scroll position.
- For composite widgets, you **must** override both `children()` and `diff()`, otherwise child state will not be created/reconciled.
- `diff()` runs during tree reconciliation. Keep it focused on reconciling state; layout and paragraph updates belong in `layout()`.
- `Tree` is not `Send`. Do not move widget state across threads.

## See also

- `advanced-widget.md`
- `advanced-shell.md`
- `guide-custom-widgets.md`
- `animation.md` — animation state must live in Tree, not widget struct
- `guide-animated-layout.md` — keyed identity, `diff_children_custom`
