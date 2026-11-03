# Subscription Recipe

Read when ordinary subscription builders or event helpers cannot express the required identity or runtime-input processing. The pinned [Recipe declaration](https://github.com/iced-rs/iced/blob/0.14.0/futures/src/subscription.rs) owns `Hasher`, `EventStream` and stream signatures. The `iced::advanced::subscription` route requires `advanced`.

## Identity

A recipe defines its output type, writes identity through `hash`, and consumes its boxed configuration in `stream`. Include a type discriminator and every input that distinguishes independent workers. Keep the hash stable while the same worker should continue.

For a recipe with an `id` and `interval`, its hash method can use:

```rust
use iced::advanced::subscription::Hasher;
use std::any::TypeId;
use std::hash::Hash;

fn hash(&self, state: &mut Hasher) {
    TypeId::of::<Self>().hash(state);
    self.id.hash(state);
    self.interval.hash(state);
}
```

This is a method excerpt for the recipe implementation. The runtime's hasher is an identity mechanism, not a cryptographic boundary. Prefer `Subscription::run_with` when hashable configuration and a stream builder are sufficient; use [time](time.md) for ordinary ticks.

## Runtime input

`EventStream` contains subscription events. An `Interaction` wraps the core event, window identity and capture status; `SystemThemeChanged` is a separate case. Do not use a stream of `iced::event::Event` as a replacement for this input type.

For example, inside a native recipe's stream body, this selects ignored keyboard events:

```rust
use iced::advanced::subscription::Event;
use iced::event::{self, Status};
use iced::futures::StreamExt;

input.filter_map(|event| async move {
    match event {
        Event::Interaction {
            event: event::Event::Keyboard(key),
            status: Status::Ignored,
            ..
        } => Some(key),
        _ => None,
    }
}).boxed()
```

The excerpt assumes a recipe whose output is `iced::keyboard::Event`. Use the declared target-dependent boxed-stream type: the [futures owner](https://github.com/iced-rs/iced/blob/0.14.0/futures/src/lib.rs) requires `Send` on native targets and uses a local boxed stream on Wasm. On Wasm the corresponding boxing method is `boxed_local()`.

A recipe can ignore runtime input and return its own stream. Filtering is the recipe's responsibility. Prefer [event helpers](events.md) when they already supply the needed filter.

## Lifetime

The [tracker](https://github.com/iced-rs/iced/blob/0.14.0/futures/src/subscription/tracker.rs) keeps an execution while its identity is requested. Removing that identity cancels the execution. Stream completion ends polling normally; it is not a fatal error. The identity remains registered until removed, so a completed worker needs an explicit restart design. See [subscription lifetime](subscription.md#identity-and-lifetime).

Keep a continuing listener active until removal, and capture configuration before the recipe is consumed. Check worker shutdown and reconnection in the target runtime. No native stream or timer result is established here.
