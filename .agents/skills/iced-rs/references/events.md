# Events

> `iced::event` · iced 0.14.0

Global event listening and filtering. The `Event` enum represents all runtime events (keyboard, mouse, window, touch, input method). Use `listen`, `listen_with`, or `listen_raw` to subscribe to events globally.

Read when subscribing to global events or distinguishing captured and ignored events.

## API

Read the [Iced 0.14.0 declarations](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/futures/src/event.rs) for subscription functions and [core event declarations](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/event.rs) for `Event` and `Status`.

## Patterns

### Subscribe to ignored events

```rust
use iced::event;

fn subscription(&self) -> Subscription<Message> {
    event::listen().map(Message::EventOccurred)
}
```

### Filter for unhandled keyboard events

```rust
use iced::event::{self, Event, Status};

fn subscription(&self) -> Subscription<Message> {
    event::listen_with(|event, status, _id| {
        if let Status::Ignored = status {
            if let Event::Keyboard(kb_event) = event {
                return Some(Message::UnhandledKey(kb_event));
            }
        }
        None
    })
}
```

### Window-specific event filtering

```rust
event::listen_with(|event, _status, window_id| {
    if let Event::Window(window::Event::Resized(size)) = event {
        Some(Message::WindowResized(window_id, size))
    } else {
        None
    }
})
```

## Gotchas

- `listen()` delivers ignored runtime events. `listen_with` can include captured events, but filters redraw requests.
- `listen_with` receives `Status` indicating whether a widget already handled the event. Check `Status::Ignored` to avoid duplicate handling.
- The `window::Id` parameter in `listen_with`/`listen_raw` identifies which window the event belongs to. Use that ID for per-window handling.
- `listen_raw` also includes redraw requests and receives the handling status. Filter to the events you need to avoid producing an application message on every redraw.
- Iced 0.14.0 exposes no `event::listen_url`. URL delivery needs a separate platform integration.

## See also

- `keyboard.md` -- `keyboard::Event` variants and key types
- `mouse.md` -- `mouse::Event` variants
- `window.md` -- `window::Event` variants
- `touch.md` -- `touch::Event` variants
- `subscription.md` -- `Subscription` creation and lifecycle
