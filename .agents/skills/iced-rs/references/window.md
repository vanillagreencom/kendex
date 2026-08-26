# Window

> `iced::window` · iced 0.14.0

Window lifecycle: open, close, resize, move, screenshot. Exposes `window::Id`, `window::Event`, `window::Settings`, and event subscriptions. Multi-window via `iced::daemon()`.

## API

### `window::Settings` struct

```rust
pub struct Settings {
    pub size: Size,
    pub maximized: bool,
    pub fullscreen: bool,
    pub position: Position,
    pub min_size: Option<Size>,
    pub max_size: Option<Size>,
    pub visible: bool,
    pub resizable: bool,
    pub closeable: bool,
    pub minimizable: bool,
    pub decorations: bool,
    pub transparent: bool,
    pub blur: bool,
    pub level: Level,
    pub icon: Option<Icon>,
    pub platform_specific: PlatformSpecific,
    pub exit_on_close_request: bool,
}
```

### `window::Event` enum

```rust
pub enum Event {
    Opened { position: Option<Point>, size: Size },
    Closed,
    Moved(Point),
    Resized(Size),
    Rescaled(f32),
    RedrawRequested(Instant),
    CloseRequested,
    Focused,
    Unfocused,
    FileHovered(PathBuf),
    FileDropped(PathBuf),
    FilesHoveredLeft,
}
```

### Event subscriptions

```rust
pub fn iced::window::resize_events() -> Subscription<(Id, Size)>;
pub fn iced::window::open_events()   -> Subscription<Id>;
pub fn iced::window::close_events()  -> Subscription<Id>;
```

- **`resize_events()`** — Subscribes to every `Event::Resized` in the
  running application, emitting `(Id, Size)`.
- **`open_events()`** — Every `Event::Opened`.
- **`close_events()`** — Every `Event::Closed`.

For everything else, use the general `event::listen_with` and match on
`Event::Window(window_event)`.

## Patterns

### Open a new window

```rust
use iced::window;
use iced::Task;

fn update(state: &mut State, message: Message) -> Task<Message> {
    match message {
        Message::NewWindow => {
            let (id, open_task) = window::open(window::Settings {
                size: iced::Size::new(800.0, 600.0),
                ..Default::default()
            });
            state.next_id = id;
            open_task.map(Message::WindowOpened)
        }
        // ...
    }
}
```


### React to resize events

```rust
fn subscription(_state: &State) -> Subscription<Message> {
    window::resize_events().map(|(_id, size)| Message::WindowResized(size))
}
```

### Close on request (with confirmation)

```rust
// In Settings:
let settings = window::Settings {
    exit_on_close_request: false,
    ..Default::default()
};

// Subscribe:
fn subscription(_: &State) -> Subscription<Message> {
    event::listen_with(|event, _status, id| {
        if let Event::Window(window::Event::CloseRequested) = event {
            Some(Message::ConfirmClose(id))
        } else {
            None
        }
    })
}

// In update, decide whether to close:
Message::ConfirmClose(id) => {
    if state.has_unsaved_changes {
        state.show_confirmation_dialog = true;
        Task::none()
    } else {
        Task::from(window::close::<Message>(id))
    }
}
```

## Gotchas

- `window::open` returns both an **id** and a `Task` — you need to store
  the id if you want to address the window later (resize, move, close).
- With `iced::application()`, there is always one main window. With
  `iced::daemon()`, you own every window — the process exits when the
  last window closes.
- `exit_on_close_request = false` means the runtime **will not** close the
  window on the user's request. You must handle `CloseRequested` and
  issue a `window::close` task yourself, otherwise the window becomes
  un-closable.
- `window::Event::RedrawRequested(Instant)` is emitted every frame — do
  not log it at info level.
- `decorations = false` removes the title bar on most platforms, but the
  behaviour on Wayland is inconsistent; test there explicitly.
- `blur = true` requires `transparent = true` to have any effect, and
  even then only works on macOS and Linux.
- `position` is a `window::Position` enum (`Default`, `Centered`,
  `Specific(Point)`), not a `Point`. Don't pass raw coordinates to the
  field directly.
- No way to query the focused window id from `update()` -- track it via `Focused` subscription.

## See also

- `application.md`
- `events.md`
- `subscription.md`
- `task.md`
