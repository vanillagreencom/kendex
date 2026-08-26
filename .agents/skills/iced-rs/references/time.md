# Time

> `iced::time` · iced 0.14.0

Re-exports of `std::time::{Duration, Instant}` plus helper functions for creating time-based subscriptions and tasks.

## API

### Re-exports

```rust
pub use std::time::Duration;
pub use std::time::Instant;
```

### Functions

```rust
/// Returns a `Subscription` that yields the current `Instant` at each interval.
/// First message after `duration`, then every `duration` thereafter.
/// Requires feature `tokio` or `smol` or WebAssembly.
pub fn every(duration: Duration) -> Subscription<Instant>;

/// Returns a `Subscription` that runs an async function at a set interval,
/// yielding the function's return value.
/// Requires feature `tokio` or `smol` or WebAssembly.
pub fn repeat<T>(
    duration: Duration,
    f: impl AsyncFn() -> T + MaybeSend + 'static,
) -> Subscription<T>
where
    T: MaybeSend + 'static;

/// Returns a `Task` that resolves to the current `Instant`.
pub fn now() -> Task<Instant>;

/// Convenience: creates a `Duration` from seconds.
pub fn seconds(amount: u64) -> Duration;

/// Convenience: creates a `Duration` from milliseconds.
pub fn milliseconds(amount: u64) -> Duration;

/// Convenience: creates a `Duration` from minutes.
pub fn minutes(amount: u64) -> Duration;

/// Convenience: creates a `Duration` from hours.
pub fn hours(amount: u64) -> Duration;

/// Convenience: creates a `Duration` from days.
pub fn days(amount: u64) -> Duration;
```

## Patterns

### Tick every second

```rust
use iced::time;
use std::time::Duration;

fn subscription(&self) -> Subscription<Message> {
    time::every(Duration::from_secs(1)).map(Message::Tick)
}

// In update:
Message::Tick(instant) => {
    self.last_tick = instant;
}
```

### Animation frame at 60 FPS

```rust
use iced::time;
use std::time::Duration;

fn subscription(&self) -> Subscription<Message> {
    if self.animating {
        time::every(Duration::from_millis(16)).map(Message::AnimationFrame)
    } else {
        Subscription::none()
    }
}
```

### Periodic async polling

```rust
use iced::time;
use std::time::Duration;

fn subscription(&self) -> Subscription<Message> {
    time::repeat(Duration::from_secs(30), async || {
        fetch_status().await
    })
    .map(Message::StatusPolled)
}
```

### Get current time as a Task

```rust
fn update(&mut self, message: Message) -> Task<Message> {
    match message {
        Message::RecordTime => time::now().map(Message::TimeRecorded),
        // ...
    }
}
```

## Gotchas

- `every()` requires the `tokio` or `smol` feature flag (or WebAssembly). Without it, the function is not available.
- `every()` yields `Subscription<Instant>`. Map to your message type: `time::every(dur).map(Message::Tick)`.
- The first tick fires after `duration`, not immediately. For an immediate first tick, combine with `Task::done(Message::Tick(Instant::now()))`.
- For animation, prefer `Shell::request_redraw` or `Shell::request_redraw_at` from within a custom widget over `time::every(16ms)`. The shell-based approach syncs with the compositor.
- `now()` returns a `Task<Instant>`, not a raw `Instant`. This is designed for pure update functions (time-travel debugging support).

## See also

- `subscription.md` -- `Subscription` lifecycle and identity
- `task.md` -- `Task` creation and chaining
- `animation.md` -- animation scheduling with `request_redraw`
- `advanced-shell.md` -- `Shell::request_redraw_at`
