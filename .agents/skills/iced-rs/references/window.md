# Window

> `iced::window` · iced 0.14.0

Read when opening, closing, moving, resizing, or capturing an Iced window, or when subscribing to its events.

## API

See [window tasks and subscriptions](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/runtime/src/window.rs), [`Settings`](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/window/settings.rs), [`Event`](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/window/event.rs), and [`Position`](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/window/position.rs).

Use `open_events()` and `close_events()` for lifecycle notifications by window ID. Use `window::events()` when you need to match another window event or handle several kinds together.

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

Keep the pending window ID so the confirm action closes the window that requested it.

```rust
// In Settings:
let settings = window::Settings {
    exit_on_close_request: false,
    ..Default::default()
};

// Subscribe:
fn subscription(_: &State) -> Subscription<Message> {
    window::close_requests().map(Message::ConfirmClose)
}

// In update, decide whether to close:
Message::ConfirmClose(id) => {
    if state.has_unsaved_changes {
        state.pending_close = Some(id);
        state.show_confirmation_dialog = true;
        Task::none()
    } else {
        window::close(id)
    }
}
```

## Gotchas

- `window::open` returns both an **id** and a `Task` — you need to store the id if you want to address the window later (resize, move, close).
- `iced::application()` opens an initial window and exits when the last window closes. Use `iced::daemon()` to manage windows explicitly. The daemon stays alive after its last window closes. Use `iced::exit()` to terminate it.
- Set `exit_on_close_request = false` on each window that needs confirmation. Handle its close request in `update` and return a `window::close` task when the user confirms.
- Iced forwards `RedrawRequested(Instant)` during redraw handling. Keep these frequent events out of info-level logs. Use `window::frames()` for redraw timestamps in a subscription.
- Set `decorations = false` to request a window without native borders and title bar. Check the result on your target platform, including Wayland if you target it.
- For blur on macOS or Linux, enable `transparent` and use a background colour with suitable opacity. See the platform notes in the linked `Settings` declaration.
- Use `Position::Specific(point)` for fixed coordinates or `Position::SpecificWith` to calculate a position from the window size and monitor resolution.
- Track focus through `Focused` and `Unfocused` events when the application needs the focused window id.

## See also

- `application.md`
- `events.md`
- `subscription.md`
- `task.md`
