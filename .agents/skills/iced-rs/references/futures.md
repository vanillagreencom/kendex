# Futures

> `iced::futures` · iced 0.14.0

Re-exports from the `futures` crate and iced-specific async utilities. Provides the `MaybeSend` trait, stream combinators, and subscription builders used throughout the iced runtime.

## API

### Key re-exports

```rust
// From the `futures` crate
pub use futures::Stream;
pub use futures::StreamExt;
pub use futures::Sink;
pub use futures::SinkExt;
pub use futures::Future;
pub use futures::FutureExt;

// iced-specific
pub use iced_futures::MaybeSend;
pub use iced_futures::subscription;
```

### `MaybeSend` trait

```rust
/// A trait that is `Send` on native platforms and relaxed on wasm32.
/// All async closures and futures passed to iced must be `MaybeSend`.
pub trait MaybeSend {}

// On native: MaybeSend = Send
// On wasm32: MaybeSend = (no Send requirement)
```

### `subscription` module

```rust
pub mod subscription {
    /// A channel type for sending messages from a subscription back
    /// to the runtime.
    pub struct Channel<Message> { /* private */ }

    impl<Message> Channel<Message> {
        pub async fn send(&mut self, message: Message);
    }
}
```

## Patterns

### Use Stream combinators

```rust
use iced::futures::StreamExt;

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

Subscription::run(|| {
    iced::stream::channel(10, async move |mut sender| {
        loop {
            let event = wait_for_event().await;
            sender.send(event).await.ok();
        }
    })
})
.map(Message::ExternalEvent)
```

## Gotchas

- `MaybeSend` is the key portability trait. On native targets it requires `Send`; on wasm32 it does not. Always use `MaybeSend` bounds (not `Send`) for futures and streams passed to iced APIs.
- `iced::futures` is a convenience re-export. You can also depend on `futures` directly, but use iced's `MaybeSend` for cross-platform compatibility.
- Stream combinators from `futures::StreamExt` (`.filter()`, `.map()`, `.take()`) work with iced subscriptions and tasks.
- The `subscription` module provides channel-based communication. For simpler cases, use `iced::stream::channel` directly.

## See also

- `stream.md` -- `stream::channel`, `stream::try_channel`
- `subscription.md` -- `Subscription::run`, `Subscription::run_with`
- `task.md` -- `Task::future`, `Task::stream`
- `time.md` -- time-based subscriptions
