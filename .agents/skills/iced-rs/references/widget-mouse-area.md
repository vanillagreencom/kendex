# Mouse Area

> `iced::widget::mouse_area` · iced 0.14.0

Wraps content to intercept mouse events: press, release, double-click, right-click, middle-click, scroll, hover enter/exit, and movement. Use when you need mouse interaction on a non-interactive widget.

## API

Iced 0.14.0 owns the declarations, bounds, feature gates and defaults: [widget/src/mouse_area.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/mouse_area.rs); [widget/src/helpers.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/helpers.rs).

## Patterns

### Click detection on text

```rust
use iced::widget::{mouse_area, text};
use iced::mouse;

mouse_area(text("Click me!"))
    .on_press(Message::TextClicked)
    .interaction(mouse::Interaction::Pointer)
```

### Hover tracking

```rust
mouse_area(content)
    .on_enter(Message::Hovered(true))
    .on_exit(Message::Hovered(false))
```

### Mouse position tracking

```rust
mouse_area(canvas_widget)
    .on_move(|point| Message::MouseMoved(point))
```

### Right-click context menu trigger

```rust
mouse_area(list_item)
    .on_right_press(Message::ShowContextMenu(item_id))
```

### Scroll interception

```rust
use iced::mouse::ScrollDelta;

mouse_area(content)
    .on_scroll(|delta| match delta {
        ScrollDelta::Lines { y, .. } => Message::ScrollLines(y),
        ScrollDelta::Pixels { y, .. } => Message::ScrollPixels(y),
    })
```

## Gotchas

- `on_press` fires on mouse-down (not mouse-up like `button`). Use this for drag initiation or immediate feedback.
- `on_move` receives widget-local coordinates. The widget uses `Cursor::position_in` to subtract its bounds origin.
- `interaction` supplies a hover cursor only when the child reports `Interaction::None`. The child's interaction takes precedence.
- `MouseArea` captures events only within its content's bounds. It does not expand to fill available space unless the content does.
- Different handler kinds can coexist. Calling the same setter again replaces its message or closure. A child that captures an event prevents the area from handling it.

## See also

- `widget-button.md` -- press-on-release semantics, disabled states
- `mouse.md` -- `ScrollDelta`, `Button`, `Interaction` types
- `advanced-mouse.md` -- `Cursor` hit-testing for custom widgets
- `guide-custom-widgets.md` -- stable hover hit regions (avoid wrapping animated bounds)
- `widgets.md` -- widget catalog
