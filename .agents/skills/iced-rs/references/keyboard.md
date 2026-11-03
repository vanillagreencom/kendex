# Keyboard

Read when implementing shortcuts, physical key bindings or keyboard subscriptions in iced 0.14.0. The pinned [event declaration](https://github.com/iced-rs/iced/blob/0.14.0/core/src/keyboard/event.rs), [key types](https://github.com/iced-rs/iced/blob/0.14.0/core/src/keyboard/key.rs) and [modifiers](https://github.com/iced-rs/iced/blob/0.14.0/core/src/keyboard/modifiers.rs) own the API and complete key inventories.

## Key selection

Use `key` with modifiers for shortcuts, `modified_key` when the binding depends on the modified logical key, and `physical_key` when the binding follows a keyboard position. `modified_key` applies modifiers except Ctrl. The [winit conversion](https://github.com/iced-rs/iced/blob/0.14.0/winit/src/conversion.rs) uses different normalization branches on native and Wasm targets; check the intended layout and backend.

Match `Key::Named` for controls such as Escape and arrows. Match `Key::Character` for character strings; do not assume the string contains one Rust `char`. `as_ref()` lets a match borrow that string. Handle unidentified logical or physical keys without assigning a universal meaning to native codes.

Use `Modifiers::COMMAND` or `modifiers.command()` for the platform's primary shortcut modifier. This selects Command on macOS and Ctrl elsewhere. `contains` permits additional modifier bits; use equality when the shortcut must reject them.

## Input handling

[`keyboard::listen()`](https://github.com/iced-rs/iced/blob/0.14.0/futures/src/keyboard.rs) receives keyboard events that widgets leave ignored. Use [event subscriptions](events.md) when the handler must inspect capture status or window identity. In a custom widget, publish the action and capture the event only when that widget handles it.

The following handler uses an application's `Message::Save` variant. It rejects repeated presses; omit that condition when holding the key should repeat the action.

```rust
use iced::keyboard::{self, Key};
use iced::Subscription;

fn subscription() -> Subscription<Message> {
    keyboard::listen().filter_map(|event| match event {
        keyboard::Event::KeyPressed {
            key, modifiers, repeat, ..
        } if key.as_ref() == Key::Character("s")
            && modifiers.command()
            && !repeat => Some(Message::Save),
        _ => None,
    })
}
```

For position-based movement, match `physical_key` against `keyboard::key::Physical::Code(keyboard::key::Code::KeyW)` and the corresponding A/S/D positions. Keep press/release state in the application when movement lasts while a key is held.

For a shortcut that deliberately maps a non-Latin layout to a Latin key, `key.to_latin(physical_key)` returns an optional character. The declaration includes a Cyrillic C example. This helper is not a general transliterator; retain the `None` branch.

Treat `text` as optional. A key event is not a complete text-editing or IME protocol. Check dead keys, composition, repeats and layout behavior on the target; these are native input checks, not guarantees from this source reference.

See [mouse input](mouse.md), [subscriptions](subscription.md) and [custom-widget event handling](advanced-widget.md).
