# Time

Read when scheduling ticks, polling async work or obtaining an instant in iced 0.14.0. The pinned [core time module](https://github.com/iced-rs/iced/blob/0.14.0/core/src/time.rs) owns time types and duration helpers; it re-exports `web_time` types for native/web use. The [root time module](https://github.com/iced-rs/iced/blob/0.14.0/src/time.rs) adds `now` and the selected backend's timer API.

## Timers

Return a timer subscription while it is needed and remove it when idle. Map emitted instants into application messages:

```rust
use iced::{time, Subscription};

fn subscription(state: &State) -> Subscription<Message> {
    if state.running {
        time::every(time::seconds(1)).map(Message::Tick)
    } else {
        Subscription::none()
    }
}
```

The [default backend selection](https://github.com/iced-rs/iced/blob/0.14.0/futures/src/backend/default.rs) determines available timer helpers. Native Tokio and smol provide `every`; the Wasm backend provides its own implementation. A thread-pool or null backend does not acquire timers by supplying an interval value. Use [subscription identity](subscription.md) to understand why changing an interval restarts its timer.

The [Tokio timer](https://github.com/iced-rs/iced/blob/0.14.0/futures/src/backend/native/tokio.rs) schedules its first `every` tick after the interval and skips missed ticks. Check the selected backend's timing behavior before relying on exact cadence. If an immediate initial timestamp is needed, return `time::now().map(Message::Tick)` as an initial task alongside the subscription.

## Async polling

The inspected Tokio backend also provides `repeat`. It takes a function returning a future, followed by the interval:

```rust
time::repeat(fetch_status, time::seconds(30))
    .map(Message::StatusPolled)
```

Here `fetch_status` is the application's async function. This implementation performs the first call immediately, then sleeps between completed calls. Its interval is not a fixed start-to-start cadence. The inspected smol and Wasm timer modules do not define this helper; do not assume Tokio's API exists on every backend.

## Instants and animation

`time::now()` returns a Task that samples the instant when polled. Return it from boot/update and handle its mapped message when pure update logic needs runtime-provided time. Duration constructors and conversion units remain at the core declaration.

A short timer interval is not a guaranteed frame rate. For custom-widget animation, follow [redraw scheduling](animation.md) and [Shell](advanced-shell.md) instead of maintaining an idle timer. Verify actual cadence, cancellation and target backend behavior in the consuming app. No native timer, browser or compositor timing result is established here.
