# Application & Daemon

> `iced::application` + `iced::daemon` · iced 0.14.0

Entry points for launching iced apps. `application(boot, update, view)` for standard windowed apps; `daemon(boot, update, view)` for starting without an initial window or managing multiple windows. Both return a builder with fluent configuration (`.theme()`, `.font()`, `.subscription()`, etc.) and `.run()` to start.

Read when defining an application entry point or choosing between application and daemon.

## API

Read the [Iced 0.14.0 declarations](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/src/application.rs) for application signatures and builder methods. Read the [daemon declarations](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/src/daemon.rs) for its window-aware callbacks.

## Patterns

### Minimal application

```rust
use iced::widget::{button, column, text, Column};

pub fn main() -> iced::Result {
    iced::application(u64::default, update, view).run()
}

#[derive(Debug, Clone)]
enum Message {
    Increment,
}

fn update(value: &mut u64, message: Message) {
    match message {
        Message::Increment => *value += 1,
    }
}

fn view(value: &u64) -> Column<'_, Message> {
    column![
        text(value),
        button("+").on_press(Message::Increment),
    ]
}
```

### Setting a theme

```rust
use iced::Theme;

pub fn main() -> iced::Result {
    iced::application(new, update, view)
        .theme(theme)
        .run()
}

fn new() -> State {
    // ...
}

fn theme(_state: &State) -> Theme {
    Theme::TokyoNight
}
```

### `iced::run(update, view)` — minimal shortcut

```rust
pub fn main() -> iced::Result {
    iced::run(update, view)
}
```

A shortcut for when you don't need a custom `boot`. Uses `Default::default()` for the state.

## Gotchas

- `Message: Send + 'static` is required — async tasks need to move messages across threads.
- `update` may return `Task<Message>` (for async effects) **or** nothing (for simple synchronous updates). Both are supported — iced infers the right form via `UpdateFn`.
- `boot` can return either a bare `State` or `(State, Task<Message>)` if you need to kick off work on startup (e.g. loading a config file).
- `.font(bytes)` configures startup fonts. Use the task returned by `font::load(bytes)` to request loading after startup.
- `iced::daemon()` runs silently without a window and keeps running after its last window closes. Return `iced::exit()` to terminate it.
- `title` accepts a static string or a state callback. Daemon title and view callbacks also receive the window ID; application callbacks do not.
- Window settings methods such as `.window_size()` and `.centered()` belong to the application builder. Open daemon windows with `window::open(settings)`.

## See also

- `element.md`
- `task.md`
- `subscription.md`
- `theme.md`
- `window.md`
