# Operation

> `iced::advanced::widget::Operation` · iced 0.14.0

Widget tree traversal trait for querying/mutating state outside the normal message loop. Focus, scroll, and text operations. Triggered via `Task::widget(op)`. Sub-modules: `focusable`, `scrollable`, `text_input`.

## API

### `Operation` trait

```rust
pub trait Operation<T> {
    // Required
    fn traverse(&mut self, operate: &mut dyn FnMut(&mut dyn Operation<T>));

    // Provided (all default to no-op)
    fn container(&mut self, _id: Option<&Id>, _bounds: Rectangle);
    fn scrollable(
        &mut self,
        _id: Option<&Id>,
        _bounds: Rectangle,
        _content_bounds: Rectangle,
        _translation: Vector,
        _state: &mut dyn Scrollable,
    );
    fn focusable(
        &mut self,
        _id: Option<&Id>,
        _bounds: Rectangle,
        _state: &mut dyn Focusable,
    );
    fn text_input(
        &mut self,
        _id: Option<&Id>,
        _bounds: Rectangle,
        _state: &mut dyn TextInput,
    );
    fn text(
        &mut self,
        _id: Option<&Id>,
        _bounds: Rectangle,
        _text: &str,
    );
    fn custom(
        &mut self,
        _id: Option<&Id>,
        _bounds: Rectangle,
        _state: &mut dyn Any,
    );

    fn finish(&self) -> Outcome<T>;
}
```

- **`traverse(operate)`** — Required. Invoked to let the operation ask the
  runtime to continue walking the tree. Most implementations just call
  `operate(self)` to recurse.
- **`container`, `scrollable`, `focusable`, `text_input`, `text`, `custom`**
  — Hook methods for each kind of widget. A widget opts into one of these
  categories by calling the corresponding method inside its `operate`
  implementation, handing over its id, bounds, and a mutable reference to
  its state object implementing the corresponding sub-trait.
- **`finish() -> Outcome<T>`** — Returns the final result of the operation
  after the tree walk is done.

### `Outcome<T>` enum

```rust
pub enum Outcome<T> {
    None,
    Some(T),
    Chain(Box<dyn Operation<T>>),
}
```

- **`None`** — The operation produced no result.
- **`Some(T)`** — The operation produced a result of type `T`.
- **`Chain(Box<dyn Operation<T>>)`** — The operation needs to be followed by
  another operation — useful for "focus the widget with this id, then
  scroll it into view" compositions.

### Sub-traits

`Focusable`:

```rust
pub trait Focusable {
    fn is_focused(&self) -> bool;
    fn focus(&mut self);
    fn unfocus(&mut self);
}
```

`Scrollable`:

```rust
pub trait Scrollable {
    fn snap_to(&mut self, offset: RelativeOffset<Option<f32>>);
    fn scroll_to(&mut self, offset: AbsoluteOffset<Option<f32>>);
    fn scroll_by(
        &mut self,
        offset: AbsoluteOffset,
        bounds: Rectangle,
        content_bounds: Rectangle,
    );
}
```

`TextInput`: (not enumerated in detail, but similar shape — query/
mutate selection, caret position, text value.)

### Built-in operation constructors

From `operation::focusable`:

- **`focus(id)`** — Produces an `Operation` that focuses the widget with the
  given `Id`.
- **`find_focused()`** — Produces an operation that searches for the
  currently focused widget and returns its `Id`. Ignores widgets without an
  `Id`.
- **`focus_next()`** — Focuses the next focusable widget after the currently
  focused one.
- **`focus_previous()`** — Focuses the previous focusable widget.
- **`is_focused(id)`** — Returns whether the widget with `id` is focused.
- **`unfocus()`** — Unfocuses the currently focused widget.
- **`count()`** — Returns a `Count` summarising the number of focusable
  widgets in the tree. Has a chain-then variant so you can build multi-stage
  operations.

From `operation::scrollable`:

- **`scroll_by(id, offset: AbsoluteOffset)`** — Scrolls the widget with the
  given id by the provided `AbsoluteOffset`.
- **`scroll_to(id, offset)`** — Scroll to an absolute offset.
- **`snap_to(id, percent)`** — Snap to a `RelativeOffset` (percent).

### `then` helper

```rust
pub fn then<A, B, O>(
    operation: impl Operation<A> + 'static,
    f: fn(A) -> O,
) -> impl Operation<B>
where
    A: 'static,
    B: Send + 'static,
    O: Operation<B> + 'static;
```

Chains the output of one operation into another, producing a new composite
operation. Lets you write things like "find the focused widget's id, then
scroll it into view".

## Patterns

### Focusing a widget by id

```rust
use iced::widget::operation::focusable::focus;
use iced::widget::Id;

let widget_id = Id::new("my_widget");
let focus_op = focus::<MyMessage>(widget_id);
// dispatch via Task::widget(focus_op)
```

### Checking focus state

```rust
use iced::widget::operation::focusable::is_focused;

let widget_id = Id::new("my_widget");
let check_op = is_focused(widget_id);
// Outcome::Some(true) if focused, Outcome::Some(false) if not
```

### Scroll by offset

```rust
use iced::{AbsoluteOffset, Id, Vector};
use iced::widget::operation::scrollable::scroll_by;

let op = scroll_by(
    Id::new("my_scrollable"),
    AbsoluteOffset::from(Vector::new(0.0, 50.0)),
);
```

### Custom operation implementation

```rust
struct MyOperation;

impl Operation<()> for MyOperation {
    fn traverse(&mut self, operate: &mut dyn FnMut(&mut dyn Operation<()>)) {
        operate(self);
    }
    // override specific hooks like `focusable`, `container`, etc.
}
```


## Gotchas

- An operation is a **mutable** visitor — you drop state into `self` as you
  walk and then pull it out in `finish()`. Don't allocate heavy structures
  per visit; reuse one.
- Widgets without an `Id` are skipped by `focusable::find_focused` and
  related helpers — if a widget should be targeted by operations, give it
  an id.
- Operations bypass the normal event loop. They **do** see widgets inside
  overlays, but only if the overlay's `Overlay::operate` forwards the
  operation (most do).
- `Outcome::Chain` is how you express "and then" — return a chain from
  `finish()` to have the runtime immediately dispatch the next operation.
  Alternatively, use the `then` helper at construction time.
- If you implement `Widget::operate`, remember to forward the operation to
  your children's trees, otherwise focus/scroll traversals will stop at
  your widget.
- The `custom` hook takes `&mut dyn Any` -- mismatched downcasts silently do nothing.

## See also

- `advanced-widget.md`
- `task.md`
- `widget-scrollable.md`
- `widget-text-input.md`
