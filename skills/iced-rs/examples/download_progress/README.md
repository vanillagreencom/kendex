# Download progress

Start several downloads and show each one’s progress.

![Multiple downloads with progress bars](https://iced.rs/examples/download_progress.gif)

[The download helper](src/download.rs) uses a byte stream to report progress to `Task::sip`. The configured download requests a model shard from Hugging Face. The server must return a content length for the example to show progress.

Read the [example source](src/main.rs).

## Run

Run from the root of the [Iced 0.14.0 workspace](../README.md#install).

```sh
cargo run --package download_progress
```
