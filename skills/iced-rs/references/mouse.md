# Mouse

Read when handling pointer buttons, wheel movement or cursor positions in iced 0.14.0. The pinned [mouse module](https://github.com/iced-rs/iced/blob/0.14.0/core/src/mouse.rs), [events](https://github.com/iced-rs/iced/blob/0.14.0/core/src/mouse/event.rs) and [buttons](https://github.com/iced-rs/iced/blob/0.14.0/core/src/mouse/button.rs) own declarations. [Cursor and interaction details](advanced-mouse.md) explain hit testing, layer visibility and click tracking.

## Input handling

The public `iced::mouse` module exposes `Cursor` and `Interaction`. Cursor position and hit-testing methods do not require the `advanced` feature. Implementing a custom Widget uses the separate [advanced API](advanced-widget.md).

Handle both line and pixel wheel deltas. Choose the conversion from lines to your application's units explicitly; the API specifies no universal pixel height for a line. [Winit conversion](https://github.com/iced-rs/iced/blob/0.14.0/winit/src/conversion.rs) preserves the separate wheel branches and converts cursor movement to window logical coordinates.

Use `cursor.is_over(layout.bounds())` before consuming a local pointer action. Use `position_in` when the handler needs widget-relative coordinates. Handle an unavailable cursor rather than inventing a position.

## Patterns

Inside a custom widget's `update`, publish and capture a handled wheel action. This excerpt uses an application-selected `line_height` and the widget's `on_scroll` callback:

```rust
use iced::{mouse, Event};

if let Event::Mouse(mouse::Event::WheelScrolled { delta }) = event {
    if cursor.is_over(layout.bounds()) {
        let amount = match delta {
            mouse::ScrollDelta::Lines { y, .. } => *y * line_height,
            mouse::ScrollDelta::Pixels { y, .. } => *y,
        };
        shell.publish((self.on_scroll)(amount));
        shell.capture_event();
    }
}
```

Apply the same bounds-and-capture pattern to `ButtonPressed(mouse::Button::Middle)`. Handle `Button::Other` as a device/platform code, without assuming a fixed button meaning.

For an application-wide forward-button action, an [event subscription](events.md) can select capture status and window identity. This handler accepts only ignored events and uses the application's `Message::Forward` variant:

```rust
use iced::{event, mouse, Event, Subscription};

fn subscription() -> Subscription<Message> {
    event::listen_with(|event, status, _window| match (event, status) {
        (
            Event::Mouse(mouse::Event::ButtonPressed(mouse::Button::Forward)),
            event::Status::Ignored,
        ) => Some(Message::Forward),
        _ => None,
    })
}
```

Track `CursorEntered` and `CursorLeft` when the application needs window-entry state. For repeated-click recognition, retain the previous click and use the helper described in [advanced mouse](advanced-mouse.md); the event enum has no double-click variant.

Verify wheel units, hit testing, button mapping and cursor feedback with the intended devices and backend. Source declarations alone do not establish those native results.

See [keyboard](keyboard.md) and [touch](touch.md).
