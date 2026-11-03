# Futures and streams

Read when composing asynchronous work for Iced 0.14.0. The [root exports](https://github.com/iced-rs/iced/blob/0.14.0/src/lib.rs) expose the upstream `futures` crate as `iced::futures`. Iced-specific [async types](https://github.com/iced-rs/iced/blob/0.14.0/futures/src/lib.rs), [target bounds](https://github.com/iced-rs/iced/blob/0.14.0/futures/src/maybe.rs) and [channel streams](https://github.com/iced-rs/iced/blob/0.14.0/futures/src/stream.rs) have separate owners.

## Composition

Import the upstream extension traits for stream, sink and future combinators. Map asynchronous results into the application's messages before handing them to a task or subscription.

```rust
use iced::futures::StreamExt;

let messages = data_stream.map(Message::DataReceived);
```

Use `task.md` for finite work and effects, `subscription.md` for the identity and lifetime of a continuing data source, and `stream.md` when a worker sends values through a bounded channel. Keep the actual producer and cancellation/error behavior with that worker. The bundled `examples/websocket/` shows a continuing connection and `examples/download_progress/` shows task-based progress.

## Target requirements

Iced's `MaybeSend` requires `Send` on native targets and relaxes it on wasm32. That trait belongs to `iced_futures`; it is not added to the upstream crate by the `iced::futures` re-export. Follow the exact bounds on the task/subscription API being called. Do not move native non-Send state into a future on the assumption that a web-compatible form also works on native.

The pinned stream helpers provide channel-based streams. There is no `iced::futures::subscription::Channel` contract in these exports. Use `iced::stream` and its declared sender type when a producer needs to send messages, with the appropriate sink extension trait and explicit handling when the receiver closes. `stream.md` owns those patterns.

## Related references

- `stream.md`
- `subscription.md`
- `task.md`
- `time.md`
