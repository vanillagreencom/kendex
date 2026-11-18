# Touch

> `iced::touch` · iced 0.14.0

Touch input events for multi-touch devices. Each touch point is identified by a unique `Finger` ID and carries a position.

Read when tracking contacts in a custom widget or subscribing to touch events.

## API

Read the [Iced 0.14.0 declarations](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/touch.rs) for signatures and available types.

## Patterns

### Handle touch in a custom widget

Keep `active_finger: Option<touch::Finger>` in the widget's tree state. Use a matching `tag()` and `state()` constructor for `TouchState`; the update fragment below accesses that state.

```rust
use iced::touch;
use iced::event::Event;

fn update(
    &mut self,
    tree: &mut Tree,
    event: &Event,
    layout: Layout<'_>,
    _cursor: Cursor,
    _renderer: &Renderer,
    _clipboard: &mut dyn Clipboard,
    shell: &mut Shell<'_, Message>,
    _viewport: &Rectangle,
) {
    let state = tree.state.downcast_mut::<TouchState>();

    if let Event::Touch(touch_event) = event {
        match touch_event {
            touch::Event::FingerPressed { id, position } => {
                if state.active_finger.is_none() && layout.bounds().contains(*position) {
                    state.active_finger = Some(*id);
                    shell.publish(Message::TouchStart(*position));
                    shell.capture_event();
                }
            }
            touch::Event::FingerMoved { id, position } => {
                if state.active_finger == Some(*id) {
                    shell.publish(Message::TouchMove(*position));
                }
            }
            touch::Event::FingerLifted { id, .. } => {
                if state.active_finger == Some(*id) {
                    state.active_finger = None;
                    shell.publish(Message::TouchEnd);
                }
            }
            touch::Event::FingerLost { id, .. } => {
                if state.active_finger == Some(*id) {
                    state.active_finger = None;
                    shell.publish(Message::TouchCanceled);
                }
            }
        }
    }
}
```

### Filter touch events globally

```rust
use iced::event::{self, Event};
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

- `FingerLost` reports cancellation. Clear the active contact as on `FingerLifted`, and send a cancellation message if the app owns gesture state.
- Touch events and mouse events are separate. A touch may also generate synthetic mouse events on some platforms. Handle both if needed.
- Use `Finger` IDs to match contact events. Use no assumptions about their numeric order.
- Multi-touch requires tracking multiple `Finger` IDs simultaneously. Use a `HashMap<Finger, Point>` for multi-finger gestures.

## See also

- `events.md` -- global event subscription including touch
- `mouse.md` -- mouse events (separate from touch)
- `advanced-mouse.md` -- `Cursor` hit-testing
- `keyboard.md` -- keyboard events
