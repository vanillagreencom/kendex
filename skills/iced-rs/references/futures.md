# Futures

> `iced::futures` · iced 0.14.0

Re-exports the `futures` crate. Provides standard stream combinators. Iced uses its separate `MaybeSend` trait internally for native and Web portability.

Read when using futures crate combinators with Iced tasks or subscriptions.

## API

Read the [Iced 0.14.0 declarations](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/futures/src/lib.rs) for the futures crate re-export and [`MaybeSend`](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/futures/src/maybe.rs) for Iced’s target-dependent bounds.

## Patterns

### Use Stream combinators

```rust
use iced::futures::{self, StreamExt};

let filtered = my_stream
    .filter(|item| futures::future::ready(item.is_valid()))
    .map(Message::DataReceived);
```

### MaybeSend in Task::future

```rust
use iced::Task;

// The future must be MaybeSend (Send on native, relaxed on wasm)
Task::future(async {
    let data = fetch_data().await;
    Message::DataLoaded(data)
})
```

### Subscription with channel

```rust
use iced::Subscription;
use iced::futures::SinkExt;

Subscription::run(|| {
    iced::stream::channel(10, async move |mut sender| {
        loop {
            let event = wait_for_event().await;
            if sender.send(event).await.is_err() {
                break;
            }
        }
    })
})
.map(Message::ExternalEvent)
```

## Gotchas

- `MaybeSend` is the key portability trait. On native targets it requires `Send`; on wasm32 it does not. Check the owning API when authoring bounds: `iced::futures` does not re-export `MaybeSend`.
- Use `iced::futures` to work with the futures crate types Iced re-exports.
- Stream combinators from `futures::StreamExt` (`.filter()`, `.map()`, `.take()`) work with iced subscriptions and tasks.
- Use `iced::stream::channel` for channel communication. `iced::futures::subscription::Channel` is unavailable.

## See also

- `stream.md` -- `stream::channel`, `stream::try_channel`
- `subscription.md` -- `Subscription::run`, `Subscription::run_with`
- `task.md` -- `Task::future`, `Task::stream`
- `time.md` -- time-based subscriptions
