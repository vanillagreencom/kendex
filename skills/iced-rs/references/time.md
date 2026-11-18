# Time

> `iced::time` · iced 0.14.0

Cross-platform time types (`Duration` and `Instant`) plus helper functions for creating time-based subscriptions and tasks.

Read when scheduling periodic work or requesting a timestamp.

## API

Read the [Iced 0.14.0 declarations](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/src/time.rs) for signatures and available types.

## Patterns

### Tick every second

```rust
use iced::time::{self, Duration};

fn subscription(&self) -> Subscription<Message> {
    time::every(Duration::from_secs(1)).map(Message::Tick)
}

// In update:
Message::Tick(instant) => {
    self.last_tick = instant;
}
```

### Application animation on an interval

```rust
use iced::time::{self, Duration};

fn subscription(&self) -> Subscription<Message> {
    if self.animating {
        time::every(Duration::from_millis(16)).map(Message::AnimationFrame)
    } else {
        Subscription::none()
    }
}
```

### Periodic async polling (native Tokio backend)

```rust
use iced::time::{self, Duration};

fn subscription(&self) -> Subscription<Message> {
    time::repeat(fetch_status, Duration::from_secs(30))
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

- `repeat(function, interval)` is exposed by the native Tokio backend. It starts the first call immediately, then waits the interval after each completed call. The builder takes a function pointer.

- `every()` requires the `tokio` or `smol` feature flag (or WebAssembly). Without it, the function is not available.
- `every()` yields `Subscription<Instant>`. Map to your message type: `time::every(dur).map(Message::Tick)`.
- The native Tokio `every` schedules its first tick after `duration`. For an immediate first tick, combine with `Task::done(Message::Tick(Instant::now()))`.
- For animation, prefer `Shell::request_redraw` or `Shell::request_redraw_at` from within a custom widget over `time::every(16ms)`. Use redraw scheduling for widget-driven animation; an interval does not guarantee a frame rate.
- Use the `Task<Instant>` returned by `now()` to receive the time as a message in `update()`.

## See also

- `subscription.md` -- `Subscription` lifecycle and identity
- `task.md` -- `Task` creation and chaining
- `animation.md` -- animation scheduling with `request_redraw`
- `advanced-shell.md` -- `Shell::request_redraw_at`
