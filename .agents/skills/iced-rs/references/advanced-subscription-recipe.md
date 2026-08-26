# Subscription Recipe (advanced)

> `iced::advanced::subscription::Recipe` · iced 0.14.0

The `Recipe` trait is the internal definition of a `Subscription`. It is used by the iced runtime to run and identify subscriptions. Most code should use `Subscription::run_with` instead; implement `Recipe` directly only when you need full control over the subscription lifecycle or must process the runtime event stream.

## API

### `Recipe` trait

```rust
pub trait Recipe {
    type Output;

    fn hash(&self, state: &mut FxHasher);

    fn stream(
        self: Box<Self>,
        input: Pin<Box<dyn Stream<Item = Event> + Send>>,
    ) -> Pin<Box<dyn Stream<Item = Self::Output> + Send>>;
}
```

- **`Output`** -- the message type emitted by this subscription.
- **`hash(&self, state)`** -- write identity bytes into `state`. The runtime uses this hash to decide whether two recipes represent the same subscription. If the hash changes between frames, the old subscription is dropped and a new one starts.
- **`stream(self, input)`** -- consume the recipe and produce an output stream. The `input` stream carries runtime `Event`s (keyboard, mouse, window, etc.) that the subscription can filter and transform. Return a `Pin<Box<dyn Stream>>` of `Self::Output`.

### Runtime `Event` (input stream)

The `input` parameter provides the full runtime event stream. The recipe can use `StreamExt::filter_map` to select relevant events. Recipes that don't need runtime events can ignore `input` entirely and produce their own stream.

## Patterns

### Minimal custom recipe

```rust
use iced::advanced::subscription::Recipe;
use iced::event::Event;
use futures::stream::{self, Stream, StreamExt};
use rustc_hash::FxHasher;
use std::hash::Hash;
use std::pin::Pin;

struct Heartbeat {
    interval: std::time::Duration,
    id: u64,
}

impl Recipe for Heartbeat {
    type Output = std::time::Instant;

    fn hash(&self, state: &mut FxHasher) {
        self.id.hash(state);
        self.interval.hash(state);
    }

    fn stream(
        self: Box<Self>,
        _input: Pin<Box<dyn Stream<Item = Event> + Send>>,
    ) -> Pin<Box<dyn Stream<Item = Self::Output> + Send>> {
        Box::pin(
            futures::stream::unfold(self.interval, |interval| async move {
                tokio::time::sleep(interval).await;
                Some((std::time::Instant::now(), interval))
            })
        )
    }
}
```

### Recipe that filters runtime events

```rust
struct KeyLogger;

impl Recipe for KeyLogger {
    type Output = String;

    fn hash(&self, state: &mut FxHasher) {
        "key-logger".hash(state);
    }

    fn stream(
        self: Box<Self>,
        input: Pin<Box<dyn Stream<Item = Event> + Send>>,
    ) -> Pin<Box<dyn Stream<Item = String> + Send>> {
        Box::pin(input.filter_map(|event| async move {
            match event {
                Event::Keyboard(kb) => Some(format!("{kb:?}")),
                _ => None,
            }
        }))
    }
}
```

### Prefer `Subscription::run_with` for simple cases

```rust
// This is simpler and covers most use cases:
Subscription::run_with(feed_id, |id| build_feed_stream(*id))
```

Only reach for `Recipe` when you need access to the runtime event stream or need custom identity hashing logic.

## Gotchas

- `Recipe` requires the `advanced` feature flag.
- The hash **must be stable** across frames for the subscription to stay alive. If any hashed field changes, the runtime treats it as a new subscription and restarts the stream.
- `FxHasher` is a non-cryptographic hasher from `rustc-hash`. Use `std::hash::Hash` to write fields into it.
- The output stream must not terminate on its own. If it does, iced treats that as a fatal error. Design streams to loop forever or use `stream::pending()` after completion.
- `stream()` takes `self: Box<Self>` -- the recipe is consumed. All configuration must be captured in the struct before the stream starts.
- The `input` event stream is shared across all recipes; filtering is your responsibility.

## See also

- `subscription.md` -- high-level `Subscription` API (`run_with`, `batch`, `map`)
- `events.md` -- `event::listen`, `event::listen_with` (simpler event filtering)
- `stream.md` -- `stream::channel`, `stream::try_channel` (async-to-stream bridge)
- `task.md` -- `Task` for one-shot async work (vs `Subscription` for long-lived)
