# Task

Read when starting or composing effects in iced 0.14.0. The pinned [Task implementation](https://github.com/iced-rs/iced/blob/0.14.0/runtime/src/task.rs) owns constructors, bounds and cancellation handles. Return the task from boot or update for the runtime to execute it.

## Choosing and composing effects

Use `Task::none()` when an update has no effect or output. Use `Task::done(value)` when an immediate value should enter the application's message loop. `perform` runs a future and maps its result; `run` maps stream items. `future` and `stream` preserve their output types.

For an application-provided async loader:

```rust
Task::perform(load_data(), Message::DataLoaded)
```

Use `batch` for concurrent effects. Use `chain` when the second task must wait until the first task's stream finishes, regardless of what values it emitted. Use `then` to start a follow-up for each output. These are execution relationships; a `Result::Err` output does not make a plain `chain` conditional on success.

```rust
Task::batch([
    Task::perform(load_config(), Message::ConfigLoaded),
    Task::perform(load_user(), Message::UserLoaded),
])
```

`collect` accumulates all outputs and emits once at completion. It does not provide partial results and cannot finish on an infinite stream. `discard` keeps effects while removing their outputs and can change the task's message type.

Futures and streams must satisfy the constructor's lifetime and [MaybeSend](futures.md) bounds. Move owned input into async work when required. Keep blocking work off the async executor through the consuming runtime's supported blocking route.

## Cancellation

`abortable` returns a task and a `Handle`. Store the handle when the application must cancel later. `abort()` requests cancellation of that stream. `abort_on_drop()` makes the last such handle clone abort when dropped; `is_aborted()` reports the request.

Stopping stream polling does not undo side effects or prove that separately spawned work stopped. Do not rely on it to interrupt synchronous work that never yields. Check cancellation behavior at the worker that owns those resources.

## Widget operations

Built-in [widget operations](https://github.com/iced-rs/iced/blob/0.14.0/runtime/src/widget/operation.rs) already return tasks. For example, with a matching widget identifier:

```rust
use iced::widget::{operation, Id};

operation::focus::<Message>(Id::new("search"))
```

For a custom `Operation`, the advanced `operate` bridge turns its output into a task. Follow the [operation contract](advanced-operation.md) instead of wrapping a built-in task as though it were a core operation.

Check ordering, failures, cancellation and target-executor compatibility in the consuming app. No async execution or local compile result is established here.

See [subscriptions](subscription.md), [streams](stream.md) and [application startup](application.md).
