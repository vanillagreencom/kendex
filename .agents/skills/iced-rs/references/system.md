# System

> `iced::system` · iced 0.14.0 · feature = `sysinfo`

Retrieves system information: OS, CPU, memory, and graphics adapter details. Returns a `Task` that resolves to an `Information` struct.

## API

### Functions

```rust
/// Retrieves available system information.
pub fn information() -> Task<Information>;
```

### `Information` struct

```rust
pub struct Information {
    pub system_name: Option<String>,
    pub system_kernel: Option<String>,
    pub system_version: Option<String>,
    pub system_short_version: Option<String>,
    pub cpu_brand: String,
    pub cpu_cores: Option<usize>,
    pub memory_total: u64,
    pub memory_used: Option<u64>,
    pub graphics_backend: String,
    pub graphics_adapter: String,
}
```

Field descriptions:

- **`system_name`** -- OS name (e.g., "Linux", "macOS", "Windows").
- **`system_kernel`** -- Kernel version string.
- **`system_version`** -- Long version (e.g., "Ubuntu 24.04 LTS").
- **`system_short_version`** -- Short version number.
- **`cpu_brand`** -- Detailed CPU model string.
- **`cpu_cores`** -- Physical core count.
- **`memory_total`** -- Total RAM in bytes.
- **`memory_used`** -- Memory used by this process in bytes.
- **`graphics_backend`** -- Rendering backend (e.g., "wgpu (Vulkan)").
- **`graphics_adapter`** -- GPU model string.

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
        text!("RAM: {} MB", info.memory_total / 1_048_576),
        text!("GPU: {}", info.graphics_adapter),
        text!("Backend: {}", info.graphics_backend),
    ]
    .spacing(4)
    .into()
}
```

## Gotchas

- Requires the `sysinfo` crate feature. Without it, the `iced::system` module is not available.
- `information()` returns a `Task`, not a direct value. It must be returned from `boot` or `update`.
- `memory_used` is the memory used by the current process, not total system memory usage.
- Some fields are `Option` -- they may be `None` on platforms where the information is unavailable.

## See also

- `task.md` -- `Task` chaining and mapping
- `application.md` -- boot function for startup tasks
- `debug.md` -- runtime profiling utilities
