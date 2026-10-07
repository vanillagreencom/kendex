## Websocket

A simple example that keeps a WebSocket connection open to an echo server.

The example consists of 3 modules:
- [`main`] contains the `Application` logic.
- [`echo`] implements a WebSocket client for the [`echo::server`] with `async-tungstenite`.
- [`echo::server`] implements a simple WebSocket echo server with `warp`.

These sources are a read-only copy. To run it, clone the upstream workspace at the release (`git clone --branch 0.14.0 https://github.com/iced-rs/iced`) and, from its root:
```
cargo run --package websocket
```

[`main`]: src/main.rs
[`echo`]: src/echo.rs
[`echo::server`]: src/echo/server.rs
