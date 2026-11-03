# Stream

Read when adapting an async producer to an iced 0.14.0 stream. The pinned [stream helpers](https://github.com/iced-rs/iced/blob/0.14.0/futures/src/stream.rs) own `channel` and `try_channel`. Use them for imperative async loops that publish values to a consumer.

## Producer

The helper polls a producer future alongside a bounded channel receiver. Choose capacity for the workload. Awaiting `send` lets the channel apply backpressure. Handle a disconnected receiver so the producer can stop; do not replace that with a tight retry loop.

```rust
use iced::futures::SinkExt;
use iced::stream;

let values = stream::channel(1, async move |mut output| {
    for value in 0..10 {
        if output.send(value).await.is_err() {
            break;
        }
    }
});
```

This produces a finite stream. A network worker can use the same pattern around its own connection/read loop; handle end-of-input and connection errors in that worker rather than repeatedly sending an absent value.

`try_channel` wraps sent values in `Ok` and yields an `Err` if its producer returns an error. The producer and receiver are selected together, so do not assume that error precedes or follows all buffered values. Handle results in the consuming application.

## Consumption

Return `Task::stream(values).map(Message::Progress)` for a finite operation. For a passive worker, build the stream through `Subscription::run` or `run_with` and return that subscription while it is needed. See [subscription identity and completion](subscription.md).

The helpers themselves do not impose a universal `'static` bound. The Task or Subscription consumer imposes its own lifetime and `MaybeSend` requirements. Capture owned data when that boundary requires it. An async operation that uses Tokio also needs a compatible executor; the helper does not install one. See [futures](futures.md) and [time](time.md).

Dropping a stream stops polling its producer future; it does not prove that external work or side effects are undone. Check shutdown, backpressure and errors in the consuming runtime. No async worker or timing run is established here.
