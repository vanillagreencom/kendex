## Download progress

A basic application that asynchronously downloads multiple dummy files of 100 MB and tracks the download progress.

The example implements a custom `Subscription` in the __[`download`](src/download.rs)__ module. This subscription downloads and produces messages that can be used to keep track of its progress.

<div align="center">
  <img src="https://iced.rs/examples/download_progress.gif">
</div>

These sources are a read-only copy. To run it, clone the upstream workspace at the release (`git clone --branch 0.14.0 https://github.com/iced-rs/iced`) and, from its root:

```
cargo run --package download_progress
```
