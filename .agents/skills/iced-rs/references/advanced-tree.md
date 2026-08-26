# Tree

> `iced::advanced::widget::tree` · iced 0.14.0

Persistent state backbone for widgets. Each widget gets a `Tree` node holding a `Tag`, a `State` (type-erased `Box<dyn Any>`), and child trees. Wired via `Widget::tag`, `Widget::state`, `Widget::children`, and `Widget::diff`.

## API

### `Tree` struct

```rust
pub struct Tree {
    pub tag: Tag,
    pub state: State,
    pub children: Vec<Tree>,
}

impl Tree {
    pub fn empty() -> Tree;

    pub fn new<'a, Message, Theme, Renderer>(
        widget: impl Borrow<dyn Widget<Message, Theme, Renderer> + 'a>,
    ) -> Tree;

    pub fn diff<'a, Message, Theme, Renderer>(
        &mut self,
        new: impl Borrow<dyn Widget<Message, Theme, Renderer> + 'a>,
    );

    pub fn diff_children<'a, Message, Theme, Renderer>(
        &mut self,
        new_children: &[impl Borrow<dyn Widget<Message, Theme, Renderer> + 'a>],
    );

    pub fn diff_children_custom<T>(
        &mut self,
        new_children: &[T],
        diff: impl Fn(&mut Tree, &T),
        new_state: impl Fn(&T) -> Tree,
    );
}
```

- **`empty()`** — An empty, stateless `Tree` with no children. Equivalent to
  `Tag::stateless()` + `State::None`.
- **`new(widget)`** — Creates a new `Tree` for the provided widget. Internally
  calls the widget's `tag()`, `state()`, and `children()`.
- **`diff(&mut self, new)`** — Reconciles the current tree with a new widget.
  If the `Tag` of `new` matches the tree's `Tag`, then `Widget::diff` is
  called (a shallow reconcile). Otherwise, the whole tree is recreated from
  scratch via `Tree::new(new)`.
- **`diff_children(&mut self, new_children)`** — Reconciles the children vec
  with a list of widgets.
- **`diff_children_custom(...)`** — Same, but for composite containers where
  children are not raw `Widget` trait objects — you supply custom `diff` and
  `new_state` closures.

### `Tag` struct

```rust
pub struct Tag(/* private fields */);

impl Tag {
    pub fn of<T>() -> Tag where T: 'static;
    pub fn stateless() -> Tag;
}
```

- **`Tag::of::<T>()`** — Identifies a widget state of type `T`. Tags are
  compared during diffing; if the tag changes, the stored `State` is wiped
  and recreated.
- **`Tag::stateless()`** — The tag for widgets with no persistent state.

`Tag` derives `Copy`, `Clone`, `Eq`, `Hash`, `Ord`, `Debug`.

### `State` enum

```rust
pub enum State {
    None,
    Some(Box<dyn Any>),
}

impl State {
    pub fn new<T>(state: T) -> State where T: 'static;
    pub fn downcast_ref<T>(&self) -> &T where T: 'static;
    pub fn downcast_mut<T>(&mut self) -> &mut T where T: 'static;
}
```

- **`State::None`** — No persistent state.
- **`State::Some(Box<dyn Any>)`** — A boxed, dynamically typed state value.
- **`State::new(state)`** — Wraps any `'static` value.
- **`downcast_ref::<T>()`** — Returns `&T`. **Panics** if the downcast fails
  or the state is `State::None`.
- **`downcast_mut::<T>()`** — Same, returning `&mut T`. Same panic behaviour.

## Patterns

Declaring persistent state:

```rust
struct MyWidgetState {
    hovered_index: Option<usize>,
    animation_time: f32,
}

impl<Message, Theme, Renderer> Widget<Message, Theme, Renderer> for MyWidget {
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

- `tag()` and `state()` must agree. If `tag()` returns `Tag::of::<Foo>()`
  but `state()` returns `State::None`, `downcast_ref::<Foo>()` will panic.
- `downcast_ref` / `downcast_mut` panic on mismatch — always use the same
  concrete `T` that `state()` produced.
- Changing the state type `T` in a live widget will wipe the state (because
  the `Tag` no longer matches), resetting any persistent state such as
  scroll position.
- For composite widgets, you **must** override both `children()` and `diff()`,
  otherwise child state will not be created/reconciled.
- `diff()` is called each frame; it should be cheap. Heavy work (layout,
  paragraph shaping, etc.) belongs in `layout()`.
- `Tree` is not `Send`. Do not move widget state across threads.

## See also

- `advanced-widget.md`
- `advanced-shell.md`
- `guide-custom-widgets.md`
- `animation.md` — animation state must live in Tree, not widget struct
- `guide-animated-layout.md` — keyed identity, `diff_children_custom`
