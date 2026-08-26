# Task

> `iced::Task` · iced 0.14.0

Async effect type returned from `update()`. Wraps futures, streams, or immediate values. Composed via `batch`, `chain`, `map`, `then`. Cancellable via `Handle`.

## API

### Creation

```rust
impl<T> Task<T> {
    pub fn none() -> Task<T>;

    pub fn done(value: T) -> Task<T>
    where
        T: MaybeSend + 'static;

    pub fn batch(tasks: impl IntoIterator<Item = Task<T>>) -> Task<T>;
}

impl<T> Task<T>
where
    T: MaybeSend + 'static,
{
    pub fn perform<A>(
        future: impl Future<Output = A> + MaybeSend + 'static,
        f: impl FnOnce(A) -> T + MaybeSend + 'static,
    ) -> Task<T>;

    pub fn run<A>(
        stream: impl Stream<Item = A> + MaybeSend + 'static,
        f: impl Fn(A) -> T + MaybeSend + 'static,
    ) -> Task<T>;

    pub fn future(future: impl Future<Output = T> + MaybeSend + 'static) -> Task<T>
    where
        T: 'static;

    pub fn stream(stream: impl Stream<Item = T> + MaybeSend + 'static) -> Task<T>
    where
        T: 'static;
}
```

- **`none()`** — A no-op task. Use in `update()` when you have nothing to
  return.
- **`done(value)`** — A task that instantly produces `value` and completes.
- **`batch(tasks)`** — Combines multiple tasks into a single task running
  concurrently.
- **`perform(future, f)`** — Runs a `Future<Output = A>` to completion and
  maps the result to `Task<T>` via `f`.
- **`run(stream, f)`** — Runs a `Stream<Item = A>` and maps each item with
  `f` to produce a stream of `T`.
- **`future(future)`** — Wraps a `Future<Output = T>` directly (no mapping).
- **`stream(stream)`** — Wraps a `Stream<Item = T>` directly.

### Transformation & chaining

```rust
impl<T> Task<T>
where
    T: MaybeSend + 'static,
{
    pub fn map<O>(
        self,
        f: impl FnMut(T) -> O + MaybeSend + 'static,
    ) -> Task<O>
    where
        O: MaybeSend + 'static;

    pub fn then<O>(
        self,
        f: impl FnMut(T) -> Task<O> + MaybeSend + 'static,
    ) -> Task<O>
    where
        O: MaybeSend + 'static;

    pub fn chain(self, task: Task<T>) -> Task<T>
    where
        T: 'static;

    pub fn collect(self) -> Task<Vec<T>>;

    pub fn discard<O>(self) -> Task<O>
    where
        O: MaybeSend + 'static;
}
```

- **`map(f)`** — Transforms each output value with `f`.
- **`then(f)`** — Chains another task that depends on the output of this
  one — the FnMut is called on each emitted value and returns a follow-up
  task.
- **`chain(task)`** — Appends a task that runs after this one completes,
  without depending on its output.
- **`collect()`** — Collects all output values into a single `Vec<T>`,
  emitting a single message at the end.
- **`discard()`** — Drops all output values, returning a task of a new
  type `O` that never emits.

### `Handle`

```rust
impl Handle {
    pub fn abort(&self);
    pub fn abort_on_drop(self) -> Handle;
    pub fn is_aborted(&self) -> bool;
}
```

A `Handle` can be obtained alongside a task (e.g. via `Task::abortable`) and
used to cancel the task before it finishes. `abort_on_drop` produces a
handle that auto-aborts when all its clones are dropped.

### Widget operations as tasks

```rust
pub fn iced::advanced::widget::operate<T>(
    operation: impl Operation<T> + 'static,
) -> Task<T>
where
    T: Send + 'static,
```

Builds a task that runs a widget `Operation` and produces its outcome.
Requires the `advanced` feature.

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
use iced::advanced::widget::operate;
use iced::widget::operation::focusable::focus;

operate(focus::<Message>(Id::new("search")))
```


## Gotchas

- `Task::none()` vs `Task::done(())`: use `none()` when you have nothing to
  emit, `done(())` when you explicitly want to trigger an `update(())` call.
- `then` vs `chain`: `then` depends on the previous task's output (receives
  `T`), `chain` runs the follow-up regardless of what the previous task
  emitted.
- `Task::perform` expects the `Future<Output = A>` to be `MaybeSend` and
  `'static`. Async blocks capturing non-`Send` types will fail to compile
  on desktop targets.
- `batch` runs tasks concurrently — if you need strict ordering, use
  `chain` (one after another) or `then` (dependent).
- `collect()` waits for the underlying stream to complete — it never
  emits partial results. Don't call it on infinite streams.
- `discard()` changes the output type — useful when composing with another
  task of a different message type.
- `Handle::abort()` is best-effort -- pure-sync work that never yields cannot be cancelled.

## See also

- `subscription.md`
- `application.md`
- `stream.md`
- `futures.md`
