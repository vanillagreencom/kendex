# Operation

> `iced::advanced::widget::Operation` · iced 0.14.0

Widget tree traversal trait for querying/mutating state outside the normal message loop. Focus, scroll, and text operations. Dispatch with `iced::advanced::widget::operate(op)`, which returns a `Task`. Sub-modules: `focusable`, `scrollable`, `text_input`.

Read when implementing or debugging operation behavior in a custom widget or backend. Enable Iced’s `advanced` feature for the `iced::advanced` paths used here.

## Declarations

Pinned Iced 0.14.0 declarations, signatures, defaults and implementation:

- [core/src/widget/operation.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/widget/operation.rs).
- [core/src/widget/operation/focusable.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/widget/operation/focusable.rs).
- [core/src/widget/operation/scrollable.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/widget/operation/scrollable.rs).
- [core/src/widget/operation/text_input.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/widget/operation/text_input.rs).
- [src/advanced.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/src/advanced.rs).
- [runtime/src/task.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/runtime/src/task.rs).

## Patterns

Usage fragments below assume the surrounding widget implementation, imports and application message/state types.

### Focusing a widget by id

```rust
use iced::advanced::widget::{operate, operation::focusable::focus};
use iced::widget::Id;

let widget_id = Id::new("my_widget");
let focus_task: iced::Task<MyMessage> = operate(focus(widget_id));
```

### Checking focus state

```rust
use iced::advanced::widget::operation::focusable::is_focused;
use iced::widget::Id;

let widget_id = Id::new("my_widget");
let check_op = is_focused(widget_id);
// Some(true/false) when the target is found; no outcome when it is absent.
```

### Scroll by offset

```rust
use iced::advanced::widget::operation::scrollable::{scroll_by, AbsoluteOffset};
use iced::widget::Id;

let op = scroll_by::<MyMessage>(
    Id::new("my_scrollable"),
    AbsoluteOffset { x: 0.0, y: 50.0 },
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

- In `traverse`, call the supplied closure to continue into children; omitting it skips that subtree. Widget hooks opt into focus, scroll, text or custom state visits.

- An operation is a **mutable** visitor — you drop state into `self` as you walk and then pull it out in `finish()`. Don't allocate heavy structures per visit; reuse one.
- Give a widget an `Id` for targeted operations and `find_focused`. Untargeted traversal such as `focus_next` and `count` also visits focusable state without an ID.
- The runtime applies operations to the main tree and its overlay. An overlay must forward `Overlay::operate` to expose its child state.
- `Outcome::Chain` is how you express "and then" — return a chain from `finish()` to have the runtime immediately dispatch the next operation. Alternatively, use the `then` helper at construction time.
- If you implement `Widget::operate`, remember to forward the operation to your children's trees, otherwise focus/scroll traversals will stop at your widget.
- The `custom` hook takes `&mut dyn Any`. Check the result of `downcast_mut` before using state; the operation owns mismatch handling.

## See also

- `advanced-widget.md`
- `task.md`
- `widget-scrollable.md`
- `widget-text-input.md`
