# Stream

> `iced::stream` · iced 0.14.0

Utilities for bridging async futures into the stream world. Use `channel` or `try_channel` to convert imperative async code (loops, channels) into streams consumed by `Subscription::run` or `Task::stream`.

Read when adapting asynchronous producers for a subscription or task.

## API

Read the [Iced 0.14.0 declarations](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/futures/src/stream.rs) for signatures and available types.

## Patterns

### WebSocket-like stream via channel

```rust
use iced::stream;
use iced::Subscription;
use iced::futures::{SinkExt, StreamExt};

fn subscription(&self) -> Subscription<Message> {
    Subscription::run(|| {
        stream::channel(100, async move |mut sender| {
            let mut ws = connect_websocket().await;
            while let Some(msg) = ws.next().await {
                if sender.send(msg).await.is_err() { break; }
            }
        })
    })
    .map(Message::WebSocketData)
}
```

### Fallible stream with try_channel

```rust
use iced::stream;
use iced::futures::SinkExt;

let data_stream = stream::try_channel(10, async move |mut sender| {
    let mut reader = open_file().await?;
    while let Some(chunk) = reader.next_chunk().await? {
        if sender.send(chunk).await.is_err() { break; }
    }
    Ok(())
});
```

### Use with Task::stream

```rust
use iced::stream;
use iced::Task;
use iced::futures::SinkExt;
use std::time::Duration;

Task::stream(stream::channel(1, async move |mut sender| {
    for i in 0..10 {
        tokio::time::sleep(Duration::from_millis(100)).await;
        if sender.send(i).await.is_err() { break; }
    }
}))
.map(Message::Progress)
```

## Gotchas

- `size` is the mpsc channel buffer size. Start with a small buffer such as 1–10 items for a producer that awaits each send. Size it for how much queued data the consumer can handle.
- The `Sender` is bounded -- `sender.send(item).await` will wait if the buffer is full. Never use `try_send` in a tight loop without backpressure handling.
- `try_channel` wraps each item in `Result`. If the closure returns `Err`, its runner yields an error item. Buffered successful items can still drain; do not assume the error is the last emitted item.
- When used with `Subscription::run` or `Task::stream`, the resulting stream must satisfy their `MaybeSend + 'static` bounds. Capture owned data for those uses.

## See also

- `subscription.md` -- `Subscription::run` consumes streams
- `task.md` -- `Task::stream` for one-shot stream tasks
- `futures.md` -- `Stream` re-exports
- `time.md` -- `time::every` for interval-based subscriptions
