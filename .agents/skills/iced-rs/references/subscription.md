# Subscription

> `iced::Subscription` · iced 0.14.0

Declarative long-lived event source. Kept alive as long as `subscription(&State)` returns it. Use for ticks, keyboard/mouse listeners, network streams, and window events. Remove a subscription to stop its stream. A stream that completes stops emitting without an automatic restart while its identity remains selected.

Read when starting or stopping a long-lived event source.

## API

Read the [Iced 0.14.0 declarations](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/futures/src/subscription.rs) for signatures and available types.

## Patterns

### 1 Hz tick

```rust
use iced::time;
use std::time::Duration;

fn subscription(_state: &State) -> Subscription<Message> {
    time::every(Duration::from_secs(1)).map(Message::Tick)
}
```

### Filter keyboard shortcuts globally

```rust
use iced::event::{self, Event, Status};
use iced::keyboard;

fn subscription(_: &State) -> Subscription<Message> {
    event::listen_with(|event, status, _window_id| {
        if status != Status::Ignored {
            return None;
        }
        if let Event::Keyboard(keyboard::Event::KeyPressed { key, .. }) = event {
            map_global_shortcut(key)
        } else {
            None
        }
    })
}
```

### Combine multiple

```rust
Subscription::batch([
    time::every(Duration::from_millis(16)).map(Message::Tick),
    keyboard::listen().map(Message::Keyboard),
    window::close_events().map(Message::WindowClosed),
])
```

### Custom stream via `run_with`

```rust
use iced::Subscription;

fn subscribe_to_feed(state: &State) -> Subscription<Message> {
    Subscription::run_with(state.feed_id, |id| {
        // Return a Stream<Item = Message>:
        build_feed_stream(*id)
    })
}
```

## Gotchas

- Return the subscription identities the app needs for its current state. The runtime stops identities that disappear and starts new ones.
- `Subscription::run_with` uses `data` **and the function pointer** as the identity. The builder is a function pointer and cannot capture state; pass identity data explicitly.
- `.with(id)` includes the label in the subscription identity and adds it to each item as `(id, item)`.
- Keep streams alive until the subscription is removed. A completed stream stops emitting; the tracker retains its identity and does not restart it while it remains selected.
- `time::every` is exposed on native targets through the `tokio` or `smol` feature, or through the WebAssembly backend. Supplying a custom executor does not add that re-export.
- `event::listen_with` includes captured interactions but filters redraw requests. Check `Status` to avoid handling a captured interaction twice.
- Messages emitted by subscriptions go through the normal `update` loop — don't forget to handle them in your match.
- Map closures run outside the `update` context. Capture owned context if needed; send a message to mutate application state through `update`.

## See also

- `task.md`
- `time.md`
- `events.md`
- `advanced-subscription-recipe.md`
