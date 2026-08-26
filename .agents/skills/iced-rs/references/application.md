# Application & Daemon

> `iced::application` + `iced::daemon` · iced 0.14.0

Entry points for launching iced apps. `application(boot, update, view)` for standard windowed apps; `daemon(boot, update, view)` for headless/multi-window. Both return a builder with fluent configuration (`.theme()`, `.font()`, `.subscription()`, etc.) and `.run()` to start.

## API

### `iced::application(boot, update, view)`

```rust
pub fn application<State, Message, Theme, Renderer>(
    boot: impl BootFn<State, Message>,
    update: impl UpdateFn<State, Message>,
    view: impl for<'a> ViewFn<'a, State, Message, Theme, Renderer>,
) -> Application<impl Program<State = State, Message = Message, Theme = Theme>>
where
    State: 'static,
    Message: Send + 'static,
    Theme: Base,
    Renderer: Renderer,
```

### `iced::daemon(boot, update, view)`

```rust
pub fn daemon<State, Message, Theme, Renderer>(
    boot: impl BootFn<State, Message>,
    update: impl UpdateFn<State, Message>,
    view: impl for<'a> ViewFn<'a, State, Message, Theme, Renderer>,
) -> Daemon<impl Program<State = State, Message = Message, Theme = Theme>>
```

### Builder methods (shared by both)

`.title(fn)`, `.subscription(fn)`, `.theme(fn)`, `.style(fn)`, `.scale_factor(fn)`, `.settings(Settings)`, `.antialiasing(bool)`, `.default_font(Font)`, `.font(bytes)`, `.window_size(Size)`, `.centered()`, `.resizable(bool)`, `.run()`.

### Function signatures

- `boot`: `fn() -> State` or `fn() -> (State, Task<Message>)`
- `update`: `fn(&mut State, Message)` or `fn(&mut State, Message) -> Task<Message>`
- `view`: `fn(&State) -> Element<Message>`

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

fn view(value: &u64) -> Column<Message> {
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

fn theme(state: &State) -> Theme {
    Theme::TokyoNight
}
```

### `iced::run(update, view)` — minimal shortcut

```rust
pub fn main() -> iced::Result {
    iced::run(update, view)
}
```

A shortcut for when you don't need a custom `boot`. Uses
`Default::default()` for the state.

## Gotchas

- `Message: Send + 'static` is required — async tasks need to move messages
  across threads.
- `update` may return `Task<Message>` (for async effects) **or** nothing
  (for simple synchronous updates). Both are supported — iced infers the
  right form via `UpdateFn`.
- `boot` can return either a bare `State` or `(State, Task<Message>)` if
  you need to kick off work on startup (e.g. loading a config file).
- `.font(bytes)` loads fonts **synchronously** at startup — fine for a few
  KB, but large fonts will delay first paint. Use `font::load(bytes)` from
  within `boot` if you want async loading.
- `iced::daemon()` will exit immediately if you don't open a window from
  `boot` (via `Task::from(window::open(...))`) — a silent daemon with no
  windows has nothing to render.
- Only one `iced::application()` or `iced::daemon()` per process.
- The builder's `title` is a function that re-evaluates on each state change.

## See also

- `element.md`
- `task.md`
- `subscription.md`
- `theme.md`
- `window.md`
