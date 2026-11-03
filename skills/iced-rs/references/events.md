# Runtime events

Read when subscribing to Iced 0.14.0 input or window events. The pinned [event subscription implementation](https://github.com/iced-rs/iced/blob/0.14.0/futures/src/event.rs) owns filtering, status and redraw behavior. The [root exports](https://github.com/iced-rs/iced/blob/0.14.0/src/lib.rs) own the public `iced::event` API.

## Listener choice

`listen()` reports ignored runtime interaction events. It filters out events captured by widgets; it is not a listener for every event.

Use `listen_with` when the application needs to filter by event, capture status or window ID. Return a message to deliver it or `None` to discard it. This listener excludes redraw requests and system-theme subscription events.

```rust
iced::event::listen_with(|event, status, window_id| {
    if status == iced::event::Status::Ignored {
        if let iced::Event::Keyboard(key) = event {
            return Some(Message::UnhandledKey(window_id, key));
        }
    }
    None
})
```

Retain the window ID when one handler serves several windows. Check `Ignored` when a global shortcut should not also handle a widget's captured input. Use the event's keyboard, mouse, window, touch or input-method type for its details; their owning declarations supply the variant inventory.

## Redraws and host events

`listen_raw` also includes redraw interaction events and passes their status. It does not promise delivery before widget processing. Filter it carefully: producing a message for each redraw can sustain another update/redraw loop. `animation.md` owns deliberate redraw loops.

The pinned root event module exports these three listeners. It does not export `listen_url`. A native URL-opening requirement needs its actual supported host integration and evidence before choosing an API; this reference establishes no URL-delivery behavior.

## Related references

- `keyboard.md`
- `mouse.md`
- `window.md`
- `touch.md`
- `subscription.md`
- `animation.md`
