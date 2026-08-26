# Subscription

> `iced::Subscription` · iced 0.14.0

Declarative long-lived event source. Kept alive as long as `subscription(&State)` returns it. Use for ticks, keyboard/mouse listeners, network streams, and window events. Streams must not end on their own -- remove the subscription to stop it.

## API

### Constructors

```rust
impl<T> Subscription<T> {
    pub fn none() -> Subscription<T>;

    pub fn batch(
        subscriptions: impl IntoIterator<Item = Subscription<T>>,
    ) -> Subscription<T>;

    pub fn run_with<D, S>(
        data: D,
        builder: fn(&D) -> S,
    ) -> Subscription<T>
    where
        D: Hash + 'static,
        S: Stream<Item = T> + MaybeSend + 'static,
        T: 'static;
}
```

- **`none()`** — Empty subscription. Use when the current state has no
  passive work.
- **`batch(iter)`** — Combines several subscriptions into one.
- **`run_with(data, builder)`** — The lowest-level constructor: produce a
  stream identified by `data` (which is hashed to deduplicate active
  subscriptions) and a `builder` that constructs the `Stream`. Both the
  data and the function pointer form the identity — if they change between
  frames, the old stream is dropped and a new one is started.

### Transformation

```rust
impl<T> Subscription<T> {
    pub fn map<O>(
        self,
        f: impl Fn(T) -> O + MaybeSend + 'static,
    ) -> Subscription<O>;

    pub fn with<A>(self, data: A) -> Subscription<(A, T)>
    where
        A: MaybeSend + Clone + 'static;
}
```

- **`map(f)`** — Transform each emitted value via `f`.
- **`with(data)`** — Pair each emission with the given data, so downstream
  handlers know which instance of a subscription produced it.

### Helper functions

From `iced::event`:

```rust
pub fn iced::event::listen() -> Subscription<Event>;
pub fn iced::event::listen_with<Message>(
    f: fn(Event, Status, Id) -> Option<Message>,
) -> Subscription<Message>;
```

- **`event::listen()`** — Subscribe to every runtime `Event` for every
  window.
- **`event::listen_with(f)`** — Filter: `f` runs for every event; `None`
  skips, `Some(message)` forwards. `f` receives `Event`, `Status` (whether
  the event was captured already) and `Id` (the window the event belongs
  to).

From `iced::keyboard`:

```rust
pub fn iced::keyboard::listen() -> Subscription<Event>;
```

From `iced::time`:

```rust
pub fn iced::time::every(duration: Duration) -> Subscription<Instant>;
```

Fires every `duration`, emitting the current `Instant`. Requires either
the `tokio` or `smol` feature, or a `wasm32` target.

From `iced::window`:

```rust
pub fn window::resize_events() -> Subscription<(Id, Size)>;
pub fn window::open_events()   -> Subscription<Id>;
pub fn window::close_events()  -> Subscription<Id>;
```

## Patterns

### 1 Hz tick

```rust
use iced::time;
use std::time::Duration;

fn subscription(_state: &State) -> Subscription<Message> {
    time::every(Duration::from_secs(1)).map(Message::Tick)
}
```

### Filter keyboard shortcuts globally

```rust
use iced::event::{self, Event, Status};
use iced::keyboard;

fn subscription(_: &State) -> Subscription<Message> {
    event::listen_with(|event, status, _window_id| {
        if status != Status::Ignored {
            return None;
        }
        if let Event::Keyboard(keyboard::Event::KeyPressed { key, .. }) = event {
            map_global_shortcut(key)
        } else {
            None
        }
    })
}
```

### Combine multiple

```rust
Subscription::batch([
    time::every(Duration::from_millis(16)).map(Message::Tick),
    keyboard::listen().map(Message::Keyboard),
    window::close_events().map(Message::WindowClosed),
])
```

### Custom stream via `run_with`

```rust
use iced::Subscription;
use futures_util::stream::Stream;

fn subscribe_to_feed(state: &State) -> Subscription<Message> {
    Subscription::run_with(state.feed_id, |id| {
        // Return a Stream<Item = Message>:
        build_feed_stream(*id)
    })
}
```


## Gotchas

- Subscriptions are **re-queried after every `update`**. If `subscription(&state)`
  returns a different set, the old subscriptions are dropped and new ones
  started. This is how you "enable" and "disable" subscriptions reactively.
- `Subscription::run_with` uses `data` **and the function pointer** as the
  identity. Two closures that capture different state are different
  subscriptions.
- A `Subscription` is "not allowed to end on its own" — if your `Stream`
  completes, iced treats that as a fatal error. Use `run_with` streams
  that loop forever, or terminate by removing the subscription from
  `subscription(&State)`.
- `time::every` requires a runtime — if you disable both `tokio` and
  `smol` features, you must provide your own executor.
- `event::listen_with` receives **every** event, including those already
  handled by a widget. Check the `Status` argument to decide whether to
  produce a message.
- Messages emitted by subscriptions go through the normal `update` loop —
  don't forget to handle them in your match.
- Map closures run outside the `update` context and cannot touch application state.

## See also

- `task.md`
- `time.md`
- `events.md`
- `advanced-subscription-recipe.md`
