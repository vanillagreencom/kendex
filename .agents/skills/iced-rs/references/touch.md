# Touch

Read when handling touch gestures in iced 0.14.0. The pinned [touch declaration](https://github.com/iced-rs/iced/blob/0.14.0/core/src/touch.rs) owns contact events and `Finger`. [Winit conversion](https://github.com/iced-rs/iced/blob/0.14.0/winit/src/conversion.rs) maps backend IDs and converts positions to window logical coordinates.

## Contact ownership

Use the finger ID to match a contact's press, movement and end. Treat IDs as opaque; do not assume sequential numbering or permanent uniqueness. Start a local gesture only when the press is inside the widget's bounds. Convert from window coordinates when the gesture needs a local position.

Once accepted, retain the active ID until lift or cancellation. `FingerLost` denotes cancellation; clean up the same contact state as on lift without assuming why the platform canceled it. Multi-touch needs state per ID, such as a map from `Finger` to position.

The [bundled Multitouch example](../examples/multitouch/src/main.rs) updates an application-owned finger map and treats both lifted and lost events as removal. A custom Widget can instead keep persistent gesture state in its [Tree](advanced-tree.md).

## Widget pattern

Inside a Widget's `update`, this excerpt assumes a `GestureState` stored in the tree and application-defined touch messages:

```rust
use iced::{touch, Event};

let state = tree.state.downcast_mut::<GestureState>();

if let Event::Touch(event) = event {
    match event {
        touch::Event::FingerPressed { id, position }
            if state.active.is_none() && layout.bounds().contains(*position) =>
        {
            state.active = Some(*id);
            shell.publish(Message::TouchStart(*position));
            shell.capture_event();
        }
        touch::Event::FingerMoved { id, position }
            if state.active == Some(*id) =>
        {
            shell.publish(Message::TouchMove(*position));
            shell.capture_event();
        }
        touch::Event::FingerLifted { id, .. }
        | touch::Event::FingerLost { id, .. }
            if state.active == Some(*id) =>
        {
            state.active = None;
            shell.publish(Message::TouchEnd);
            shell.capture_event();
        }
        _ => {}
    }
}
```

If cancellation must differ from a successful finish, give the lost branch a separate application message while still clearing the active ID. Use [event subscriptions](events.md) for global observation and deliberately select capture status and window identity.

Mouse and touch have separate event forms. Check the target's synthetic-pointer behavior before handling both for the same action, so one gesture does not publish twice. Device mapping, loss delivery, gesture capture and rendered feedback remain native checks; none ran for this source reference.

See [mouse](mouse.md), [cursor coordinates](advanced-mouse.md) and [keyboard](keyboard.md).
