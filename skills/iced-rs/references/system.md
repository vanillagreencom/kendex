# System

Read when collecting about-dialog or diagnostic information in iced 0.14.0. The pinned [runtime system API](https://github.com/iced-rs/iced/blob/0.14.0/runtime/src/system.rs) owns the information fields and tasks. The [root exports](https://github.com/iced-rs/iced/blob/0.14.0/src/lib.rs) gate `Information` and `information()` behind `sysinfo`; the module's theme observation functions remain available without that feature.

## Information

Return `system::information()` from boot or update and map its output to an application message. The task requests a snapshot; constructing and dropping it does not query the system.

```rust
use iced::{system, Task};

fn boot() -> (State, Task<Message>) {
    (
        State::default(),
        system::information().map(Message::SystemInfoReceived),
    )
}
```

In `Message::SystemInfoReceived(info)`, store the snapshot in application state and return `Task::none()`. The [bundled system-information example](../examples/system_information/src/main.rs) demonstrates the request and display together.

Use the declaration's field meanings when displaying the result. CPU core count means physical cores. Total memory and current-process memory use bytes; the latter is not total system memory usage. Graphics fields describe the active adapter/backend. Keep optional OS, CPU and process-memory values unavailable when absent; do not display zero as an observed value.

The [winit system action](https://github.com/iced-rs/iced/blob/0.14.0/winit/src/lib.rs) collects information only when its compositor is available. Do not assume a request always produces an application message in every runtime state.

## Theme observation

`system::theme()` requests the current system theme mode. `system::theme_changes()` subscribes to changes. See [themes](theme.md) for application appearance and [subscriptions](subscription.md) for passive lifetime.

Verify available fields and native theme behavior on the intended platform. No local machine-information request or platform result is established here.

See [tasks](task.md), [application startup](application.md) and [debugging](debug.md).
