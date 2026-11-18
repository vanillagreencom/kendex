# System

> `iced::system` · iced 0.14.0

Enable `sysinfo` to query the operating system, processor, memory, and graphics adapter through an `Information` task.

Read when displaying system information or choosing the system theme.

## API

Read the [Iced 0.14.0 declarations](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/runtime/src/system.rs) for signatures and available types.

## Patterns

### Fetch system info on startup

```rust
use iced::system;

fn boot() -> (State, Task<Message>) {
    let state = State::default();
    let task = system::information().map(Message::SystemInfoReceived);
    (state, task)
}

fn update(state: &mut State, message: Message) -> Task<Message> {
    match message {
        Message::SystemInfoReceived(info) => {
            state.system_info = Some(info);
            Task::none()
        }
        // ...
    }
}
```

### Display in an about dialog

```rust
fn view_about(info: &system::Information) -> Element<'_, Message> {
    column![
        text!("OS: {}", info.system_name.as_deref().unwrap_or("Unknown")),
        text!("CPU: {} ({} cores)",
            info.cpu_brand,
            info.cpu_cores.unwrap_or(0)
        ),
        text!("RAM: {} MiB", info.memory_total / 1_048_576),
        text!("GPU: {}", info.graphics_adapter),
        text!("Backend: {}", info.graphics_backend),
    ]
    .spacing(4)
    .into()
}
```

## Gotchas

- Requires the `sysinfo` crate feature. Without it, `Information` and `information()` are unavailable; system theme APIs remain available.
- Return the task from `boot` or `update` so the runtime can run it.
- `memory_used` is the memory used by the current process, not total system memory usage.
- Some fields are `Option` -- they may be `None` on platforms where the information is unavailable.

## See also

- `task.md` -- `Task` chaining and mapping
- `application.md` -- boot function for startup tasks
- `debug.md` -- runtime profiling utilities
