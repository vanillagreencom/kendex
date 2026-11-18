# Task

> `iced::Task` · iced 0.14.0

Async effect type returned from `update()`. Wraps futures, streams, or immediate values. Composed via `batch`, `chain`, `map`, `then`. Cancellable via `Handle`.

Read when composing, returning, or cancelling an effect in application code.

## API

Read the [Iced 0.14.0 declarations](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/runtime/src/task.rs) for task methods and cancellation. See [runtime widget operations](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/runtime/src/widget/operation.rs) for task-returning operations.

## Patterns

### No-op return from update

```rust
fn update(state: &mut State, message: Message) -> Task<Message> {
    match message {
        Message::Incremented => {
            state.count += 1;
            Task::none()
        }
    }
}
```

### Kick off an async call

```rust
Task::perform(
    async { reqwest::get("https://example.com/data").await },
    Message::DataLoaded,
)
```

### Combine several tasks

```rust
Task::batch([
    Task::perform(load_config(), Message::ConfigLoaded),
    Task::perform(load_user(),   Message::UserLoaded),
])
```

### Chain tasks sequentially

```rust
Task::perform(step_one(), Message::One)
    .chain(Task::perform(step_two(), Message::Two))
```

### Fire widget operation

```rust
use iced::widget::{Id, operation};

operation::focus::<Message>(Id::new("search"))
```

## Gotchas

- `Task::none()` vs `Task::done(())`: use `none()` when you have nothing to emit, `done(())` when you explicitly want to trigger an `update(())` call.
- `then` starts a dependent task for each emitted output. `chain` starts its follow-up after the first task completes, even if it emitted no output.
- `Task::perform` expects the `Future<Output = A>` to be `MaybeSend` and `'static`. Async blocks capturing non-`Send` types will fail to compile on desktop targets.
- `batch` runs tasks concurrently — if you need strict ordering, use `chain` (one after another) or `then` (dependent).
- `collect()` waits for the underlying stream to complete — it never emits partial results. Don't call it on infinite streams.
- `discard()` keeps the effect, drops output values, and lets the caller choose the new output type when composing tasks.
- `Handle::abort()` requests cancellation; work already being polled can continue until that poll returns. Synchronous work that never returns from polling cannot be interrupted by this handle.
- `abortable()` returns a task and its cancellation handle. A manual handle does not abort on drop; `.abort_on_drop()` requests cancellation when its final clone is dropped.

## See also

- `subscription.md`
- `application.md`
- `stream.md`
- `futures.md`
