# Subscription Recipe (advanced)

> `iced::advanced::subscription::Recipe` · iced 0.14.0

The `Recipe` trait is the internal definition of a `Subscription`. It is used by the iced runtime to run and identify subscriptions. Most code should use `Subscription::run_with` instead; implement `Recipe` directly only when you need full control over the subscription lifecycle or must process the runtime event stream.

Read when implementing or debugging subscription recipe behavior in a custom widget or backend. Enable Iced’s `advanced` feature for the `iced::advanced` paths used here.

## Declarations

Pinned Iced 0.14.0 declarations, signatures, defaults and implementation:

- [futures/src/subscription.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/futures/src/subscription.rs).
- [futures/src/subscription/tracker.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/futures/src/subscription/tracker.rs).
- [src/advanced.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/src/advanced.rs).

## Patterns

Usage fragments below assume the surrounding widget implementation, imports and application message/state types.

### Minimal custom recipe

The snippets below target a native build with Tokio and its time driver enabled. They use the subscription event wrapper, which carries a window and capture status as well as the UI event. Use platform-compatible boxed streams for WebAssembly.

```rust
use iced::advanced::subscription::{Recipe, Event, EventStream, Hasher};
use iced::futures::{Stream, StreamExt};
use std::hash::Hash;
use std::pin::Pin;

struct Heartbeat {
    interval: std::time::Duration,
    id: u64,
}

impl Recipe for Heartbeat {
    type Output = std::time::Instant;

    fn hash(&self, state: &mut Hasher) {
        std::any::TypeId::of::<Self>().hash(state);
        self.id.hash(state);
        self.interval.hash(state);
    }

    fn stream(
        self: Box<Self>,
        _input: EventStream,
    ) -> Pin<Box<dyn Stream<Item = Self::Output> + Send>> {
        Box::pin(
            iced::futures::stream::unfold(self.interval, |interval| async move {
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

    fn hash(&self, state: &mut Hasher) {
        std::any::TypeId::of::<Self>().hash(state);
    }

    fn stream(
        self: Box<Self>,
        input: EventStream,
    ) -> Pin<Box<dyn Stream<Item = String> + Send>> {
        Box::pin(input.filter_map(|event| async move {
            match event {
                Event::Interaction { event: iced::Event::Keyboard(kb), .. } => {
                    Some(format!("{kb:?}"))
                }
                _ => None,
            }
        }))
    }
}
```

Build the subscription with `iced::advanced::subscription::from_recipe(Heartbeat { interval, id })` and return it from the application’s subscription function.

### Prefer `Subscription::run_with` for simple cases

```rust
// This is simpler and covers most use cases:
Subscription::run_with(feed_id, |id| build_feed_stream(*id))
```

Only reach for `Recipe` when you need access to the runtime event stream or need custom identity hashing logic.

## Gotchas

- `Recipe` requires the `advanced` feature flag.
- The hash **must be stable** across frames for the subscription to stay alive. If any hashed field changes, the runtime treats it as a new subscription and restarts the stream.
- Use the exported `Hasher` alias and `std::hash::Hash`. Include the recipe type and every field that distinguishes a data source in its identity.
- A completed stream ends normally. The tracker retains its identity while that recipe remains requested, so returning it again does not restart it. Remove the recipe before requesting that identity again when a restart is needed.
- `stream()` takes `self: Box<Self>` -- the recipe is consumed. All configuration must be captured in the struct before the stream starts.
- The tracker broadcasts events to each recipe’s input channel. Filter that stream for the windows, event kinds and capture statuses your recipe needs.

## See also

- `subscription.md` -- high-level `Subscription` API (`run_with`, `batch`, `map`)
- `events.md` -- `event::listen`, `event::listen_with` (simpler event filtering)
- `stream.md` -- `stream::channel`, `stream::try_channel` (async-to-stream bridge)
- `task.md` -- `Task` for one-shot async work (vs `Subscription` for long-lived)
