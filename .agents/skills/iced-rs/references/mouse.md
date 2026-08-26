# Mouse

> `iced::mouse` · iced 0.14.0

Mouse events, buttons, scroll deltas, cursor state, and system cursor icons. `Cursor` and `Interaction` are re-exported from `iced::advanced::mouse`; the `position_in`/`is_over` methods require the `advanced` feature.

## API

### `mouse::Event` enum

```rust
pub enum Event {
    CursorEntered,
    CursorLeft,
    CursorMoved {
        position: Point,
    },
    ButtonPressed(Button),
    ButtonReleased(Button),
    WheelScrolled {
        delta: ScrollDelta,
    },
}
```

### `mouse::Button` enum

```rust
pub enum Button {
    Left,
    Right,
    Middle,
    Back,
    Forward,
    Other(u16),
}
```

### `mouse::ScrollDelta` enum

```rust
pub enum ScrollDelta {
    Lines  { x: f32, y: f32 },
    Pixels { x: f32, y: f32 },
}
```

For `Cursor` and `Interaction` details, see `advanced-mouse.md`.

## Patterns

### Listen to wheel events in a widget

```rust
fn update(
    &mut self,
    _tree: &mut Tree,
    event: &Event,
    layout: Layout<'_>,
    cursor: Cursor,
    _renderer: &Renderer,
    _clipboard: &mut dyn Clipboard,
    shell: &mut Shell<'_, Message>,
    _viewport: &Rectangle,
) {
    if let Event::Mouse(mouse::Event::WheelScrolled { delta }) = event {
        if cursor.is_over(layout.bounds()) {
            let y = match delta {
                mouse::ScrollDelta::Lines { y, .. }  => *y * 16.0,
                mouse::ScrollDelta::Pixels { y, .. } => *y,
            };
            shell.publish((self.on_scroll)(y));
            shell.capture_event();
        }
    }
}
```

### Handle a middle-click

```rust
if let Event::Mouse(mouse::Event::ButtonPressed(mouse::Button::Middle)) = event {
    if cursor.is_over(layout.bounds()) {
        shell.publish(Message::MiddleClick);
        shell.capture_event();
    }
}
```

### Global mouse listener via subscription

```rust
use iced::event::{self, Event};
use iced::mouse;

fn subscription(_: &State) -> Subscription<Message> {
    event::listen_with(|event, _status, _id| match event {
        Event::Mouse(mouse::Event::ButtonPressed(mouse::Button::Forward)) => {
            Some(Message::Forward)
        }
        _ => None,
    })
}
```

## Gotchas

- `ScrollDelta::Lines` and `ScrollDelta::Pixels` are both emitted by real
  devices — always handle both. A common mistake is to only match on
  `Lines` and silently drop trackpad scrolling.
- "One line" is typically 16 px, but that's not guaranteed — document
  your multiplier choice.
- `CursorMoved { position }` is in **window** coordinates, not widget
  coordinates. Use `Cursor::position_in(layout.bounds())` inside a widget
  to get widget-relative coordinates.
- The public `mouse` module and the `advanced::mouse` module share the
  same types but the extended `Cursor::position_in`/`position_over`/`is_over`
  methods are gated behind the `advanced` feature flag.
- `Button::Other(u16)` is platform-specific — don't assume any particular
  numeric code means a particular button.
- There is no `Event::DoubleClick` variant — double-click detection is
  done via the `iced::advanced::mouse::click::Click::new(position, button,
  previous)` helper. If you need timing-based double-click, track
  timestamps yourself.
- No `is_inside_window` helper -- track `CursorEntered`/`CursorLeft` yourself.

## See also

- `advanced-mouse.md`
- `keyboard.md`
- `events.md`
- `touch.md`
