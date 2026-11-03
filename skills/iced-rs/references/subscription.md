# Subscription

Read when declaring a passive event source in iced 0.14.0. The pinned [Subscription implementation](https://github.com/iced-rs/iced/blob/0.14.0/futures/src/subscription.rs) owns constructors and transformations. A subscription takes effect when returned to the application or daemon runtime.

## Identity and lifetime

Return the same identity while a listener should stay alive. Return `Subscription::none()` when it is no longer needed. The [tracker](https://github.com/iced-rs/iced/blob/0.14.0/futures/src/subscription/tracker.rs) starts unseen identities and drops executions no longer requested.

`run` identifies a stream by its builder function. `run_with` includes both hashable data and the builder function pointer. Changing those inputs replaces the execution. The builder cannot capture application state; pass the required configuration as data and return a stream that owns what it needs.

For a continuing listener, keep producing until the application removes it. If a stream completes, this tracker ends its execution normally; completion is not a fatal runtime error. The identity remains registered while requested, so returning it again does not automatically restart the completed stream. Make reconnection part of the worker or explicitly change the subscription lifecycle.

The [winit update loop](https://github.com/iced-rs/iced/blob/0.14.0/winit/src/lib.rs) evaluates subscriptions after processing a batch of application messages. Do not rely on a new execution after every message or view call.

## Patterns

Enable a timer from application state. This assumes a configured timer backend and an application's `Message::Tick` variant:

```rust
use iced::{time, Subscription};
use std::time::Duration;

fn subscription(state: &State) -> Subscription<Message> {
    if state.running {
        time::every(Duration::from_secs(1)).map(Message::Tick)
    } else {
        Subscription::none()
    }
}
```

For a configured feed, use `Subscription::run_with(state.feed_id, |id| build_feed_stream(*id))`. The application's builder supplies the stream; its data must distinguish independent feeds. Combine sources with `Subscription::batch` rather than creating a separate runtime.

`map` transforms outputs. `filter_map` can skip them. Their closures must not capture values. Use `with` when emitted messages need instance context; that context also contributes to identity. Handle resulting messages in the normal application update.

## Event sources

Use [event subscriptions](events.md) for status/window selection, [keyboard input](keyboard.md) for ignored-key shortcuts, [window events](window.md) for window lifecycle and [time](time.md) for timer features. `event::listen` receives ignored non-redraw events, while `listen_with` can inspect captured events too; it still excludes redraws. Use the raw listener only deliberately.

Use [Recipe](advanced-subscription-recipe.md) for custom hashing or runtime-input processing that these helpers cannot express. [Stream](stream.md) adapts an async producer; [Task](task.md) handles effects started on demand.

Check source identity, reconnect/removal behavior and target executor in the consuming app. This reference establishes source semantics, not a native subscription or timing result.
