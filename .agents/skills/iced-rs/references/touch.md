# Touch

> `iced::touch` · iced 0.14.0

Touch input events for multi-touch devices. Each touch point is identified by a unique `Finger` ID and carries a position.

## API

### `Event` enum

```rust
pub enum Event {
    FingerPressed {
        id: Finger,
        position: Point,
    },
    FingerMoved {
        id: Finger,
        position: Point,
    },
    FingerLifted {
        id: Finger,
        position: Point,
    },
    FingerLost {
        id: Finger,
        position: Point,
    },
}
```

### `Finger` struct

```rust
pub struct Finger(pub u64);
```

A unique identifier for a touch point. The runtime assigns this when a finger makes contact and reuses it across `FingerMoved` and `FingerLifted` events for the same contact.

## Patterns

### Handle touch in a custom widget

```rust
use iced::touch;
use iced::event::Event;

fn update(
    &mut self,
    tree: &mut Tree,
    event: &Event,
    layout: Layout<'_>,
    cursor: Cursor,
    _renderer: &Renderer,
    _clipboard: &mut dyn Clipboard,
    shell: &mut Shell<'_, Message>,
    _viewport: &Rectangle,
) {
    if let Event::Touch(touch_event) = event {
        match touch_event {
            touch::Event::FingerPressed { id, position } => {
                if layout.bounds().contains(*position) {
                    self.active_finger = Some(*id);
                    shell.publish(Message::TouchStart(*position));
                    shell.capture_event();
                }
            }
            touch::Event::FingerMoved { id, position } => {
                if self.active_finger == Some(*id) {
                    shell.publish(Message::TouchMove(*position));
                }
            }
            touch::Event::FingerLifted { id, .. } => {
                if self.active_finger == Some(*id) {
                    self.active_finger = None;
                    shell.publish(Message::TouchEnd);
                }
            }
            touch::Event::FingerLost { id, .. } => {
                if self.active_finger == Some(*id) {
                    self.active_finger = None;
                }
            }
        }
    }
}
```

### Filter touch events globally

```rust
use iced::event::{self, Event, Status};
use iced::touch;

event::listen_with(|event, _status, _id| {
    if let Event::Touch(touch::Event::FingerPressed { position, .. }) = event {
        Some(Message::TouchDetected(position))
    } else {
        None
    }
})
```

## Gotchas

- `FingerLost` fires when the system loses track of a finger (e.g., the finger moves outside the touchscreen boundary). Treat it like `FingerLifted` for cleanup.
- Touch events and mouse events are separate. A touch may also generate synthetic mouse events on some platforms. Handle both if needed.
- `Finger(u64)` IDs are opaque and platform-assigned. Do not assume sequential numbering.
- Multi-touch requires tracking multiple `Finger` IDs simultaneously. Use a `HashMap<Finger, Point>` for multi-finger gestures.

## See also

- `events.md` -- global event subscription including touch
- `mouse.md` -- mouse events (separate from touch)
- `advanced-mouse.md` -- `Cursor` hit-testing
- `keyboard.md` -- keyboard events
