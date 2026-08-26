# Stream

> `iced::stream` · iced 0.14.0

Utilities for bridging async futures into the stream world. Use `channel` or `try_channel` to convert imperative async code (loops, channels) into streams consumed by `Subscription::run` or `Task::stream`.

## API

### Functions

```rust
/// Creates a `Stream` that yields items sent from a `Future` to an
/// `mpsc::Sender`. A more ergonomic `stream::unfold` -- loop and publish
/// from inside a `Future`.
pub fn channel<T>(
    size: usize,
    f: impl AsyncFnOnce(Sender<T>),
) -> impl Stream<Item = T>;

/// Like `channel`, but the async closure may return an error.
/// The stream yields `Result<T, E>` items.
pub fn try_channel<T, E>(
    size: usize,
    f: impl AsyncFnOnce(Sender<T>) -> Result<(), E>,
) -> impl Stream<Item = Result<T, E>>;
```

## Patterns

### WebSocket-like stream via channel

```rust
use iced::stream;
use iced::Subscription;

fn subscription(&self) -> Subscription<Message> {
    Subscription::run(|| {
        stream::channel(100, async move |mut sender| {
            let mut ws = connect_websocket().await;
            loop {
                let msg = ws.next().await;
                sender.send(msg).await.ok();
            }
        })
    })
    .map(Message::WebSocketData)
}
```

### Fallible stream with try_channel

```rust
use iced::stream;

let data_stream = stream::try_channel(10, async move |mut sender| {
    let mut reader = open_file().await?;
    while let Some(chunk) = reader.next_chunk().await? {
        sender.send(chunk).await.ok();
    }
    Ok(())
});
```

### Use with Task::stream

```rust
use iced::stream;
use iced::Task;

Task::stream(stream::channel(1, async move |mut sender| {
    for i in 0..10 {
        tokio::time::sleep(Duration::from_millis(100)).await;
        sender.send(i).await.ok();
    }
}))
.map(Message::Progress)
```

## Gotchas

- `size` is the mpsc channel buffer size. Use a small value (1-10) for backpressure-aware streams. Larger values buffer more items in memory.
- The `Sender` is bounded -- `sender.send(item).await` will wait if the buffer is full. Never use `try_send` in a tight loop without backpressure handling.
- `try_channel` wraps each item in `Result`. If the closure returns `Err`, the error is yielded as a final `Result::Err` item and the stream ends.
- The async closure runs in the runtime's async executor. It must be `'static` -- capture owned data, not references.

## See also

- `subscription.md` -- `Subscription::run` consumes streams
- `task.md` -- `Task::stream` for one-shot stream tasks
- `futures.md` -- `MaybeSend`, `Stream` re-exports
- `time.md` -- `time::every` for interval-based subscriptions
