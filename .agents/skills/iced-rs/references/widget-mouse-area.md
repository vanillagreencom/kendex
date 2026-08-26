# Mouse Area

> `iced::widget::mouse_area` · iced 0.14.0

Wraps content to intercept mouse events: press, release, double-click, right-click, middle-click, scroll, hover enter/exit, and movement. Use when you need mouse interaction on a non-interactive widget.

## API

### `MouseArea` struct

```rust
pub struct MouseArea<'a, Message, Theme = Theme, Renderer = Renderer<Renderer, Renderer>>
where
    Renderer: Renderer,
{ /* private fields */ }

impl<'a, Message, Theme, Renderer> MouseArea<'a, Message, Theme, Renderer>
where
    Renderer: Renderer,
{
    pub fn new(
        content: impl Into<Element<'a, Message, Theme, Renderer>>,
    ) -> Self;

    // Left button
    pub fn on_press(self, message: Message) -> Self;
    pub fn on_release(self, message: Message) -> Self;
    pub fn on_double_click(self, message: Message) -> Self;

    // Right button
    pub fn on_right_press(self, message: Message) -> Self;
    pub fn on_right_release(self, message: Message) -> Self;

    // Middle button
    pub fn on_middle_press(self, message: Message) -> Self;
    pub fn on_middle_release(self, message: Message) -> Self;

    // Scroll
    pub fn on_scroll(
        self,
        on_scroll: impl Fn(ScrollDelta) -> Message + 'a,
    ) -> Self;

    // Hover
    pub fn on_enter(self, message: Message) -> Self;
    pub fn on_move(
        self,
        on_move: impl Fn(Point) -> Message + 'a,
    ) -> Self;
    pub fn on_exit(self, message: Message) -> Self;

    // Cursor appearance
    pub fn interaction(self, interaction: Interaction) -> Self;
}
```

### Functions

```rust
pub fn mouse_area<'a, Message, Theme, Renderer>(
    content: impl Into<Element<'a, Message, Theme, Renderer>>,
) -> MouseArea<'a, Message, Theme, Renderer>
where
    Renderer: Renderer;
```

## Patterns

### Click detection on text

```rust
use iced::widget::{mouse_area, text};

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
- `on_move` receives absolute `Point` coordinates, not relative to the widget. Subtract `layout.bounds().position()` for local coordinates in a custom widget.
- `interaction` sets the cursor appearance when hovering. Without it, the cursor stays as `Interaction::None` (inherited from context).
- `MouseArea` captures events only within its content's bounds. It does not expand to fill available space unless the content does.
- All handler methods are additive -- you can chain multiple handlers on the same `MouseArea`.

## See also

- `widget-button.md` -- press-on-release semantics, disabled states
- `mouse.md` -- `ScrollDelta`, `Button`, `Interaction` types
- `advanced-mouse.md` -- `Cursor` hit-testing for custom widgets
- `guide-custom-widgets.md` -- stable hover hit regions (avoid wrapping animated bounds)
- `widgets.md` -- widget catalog
