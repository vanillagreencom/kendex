# Events

> `iced::event` · iced 0.14.0

Global event listening and filtering. The `Event` enum represents all runtime events (keyboard, mouse, window, touch, input method). Use `listen`, `listen_with`, or `listen_raw` to subscribe to events globally.

## API

### `Event` enum

```rust
pub enum Event {
    Keyboard(keyboard::Event),
    Mouse(mouse::Event),
    Window(window::Event),
    Touch(touch::Event),
    InputMethod(input_method::Event),
}
```

### `Status` enum

```rust
pub enum Status {
    Ignored,   // No widget handled the event
    Captured,  // A widget captured the event
}
```

### Functions

```rust
/// Listen to all runtime events. Every event is delivered to the subscriber.
pub fn listen() -> Subscription<Event>;

/// Listen and filter events. Return `Some(msg)` to produce a message,
/// `None` to discard.
pub fn listen_with<Message>(
    f: fn(Event, Status, window::Id) -> Option<Message>,
) -> Subscription<Message>
where
    Message: 'static + MaybeSend;

/// Listen to raw (un-processed) events.
pub fn listen_raw<Message>(
    f: fn(Event, Status, window::Id) -> Option<Message>,
) -> Subscription<Message>
where
    Message: 'static + MaybeSend;

/// Listen for URL open events (macOS open-url, etc.).
pub fn listen_url() -> Subscription<String>;
```

## Patterns

### Subscribe to all events

```rust
use iced::event;

fn subscription(&self) -> Subscription<Message> {
    event::listen().map(Message::EventOccurred)
}
```

### Filter for unhandled keyboard events

```rust
use iced::event::{self, Event, Status};
use iced::keyboard;

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

### Listen for opened URLs

```rust
fn subscription(&self) -> Subscription<Message> {
    event::listen_url().map(Message::UrlOpened)
}
```

## Gotchas

- `listen()` delivers every event to your `update` -- this can be noisy. Prefer `listen_with` to filter at the subscription level.
- `listen_with` receives `Status` indicating whether a widget already handled the event. Check `Status::Ignored` to avoid duplicate handling.
- The `window::Id` parameter in `listen_with`/`listen_raw` identifies which window the event belongs to. In single-window apps this is always the same ID.
- `listen_raw` delivers events before widget processing. Use sparingly -- most apps should use `listen_with`.
- `listen_url` is platform-specific (primarily macOS `open-url` protocol).

## See also

- `keyboard.md` -- `keyboard::Event` variants and key types
- `mouse.md` -- `mouse::Event` variants
- `window.md` -- `window::Event` variants
- `touch.md` -- `touch::Event` variants
- `subscription.md` -- `Subscription` creation and lifecycle
