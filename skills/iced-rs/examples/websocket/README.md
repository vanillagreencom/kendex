# WebSocket

Send messages through a WebSocket connection to a local echo server.

[The client](src/echo.rs) connects with `async-tungstenite`. [The server](src/echo/server.rs) uses `warp` and listens on `127.0.0.1:3030`.

Read the [example source](src/main.rs).

## Run

Run from the root of the [Iced 0.14.0 workspace](../README.md#install).

```sh
cargo run --package websocket
```
