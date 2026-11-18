# Keyboard

> `iced::keyboard` · iced 0.14.0

Keyboard input: `Event` (key press/release/modifiers changed), `Key` (named or character), `Modifiers` (bit flags), and `keyboard::listen()` subscription. Events arrive via `Widget::update` or global subscriptions.

Read when implementing keyboard shortcuts, physical key bindings, or ignored-key subscriptions.

## API

Read the [Iced 0.14.0 declarations](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/keyboard.rs) for module exports, [key events](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/keyboard/event.rs), [key identities](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/keyboard/key.rs), [modifiers](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/keyboard/modifiers.rs), and [`listen`](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/futures/src/keyboard.rs) for subscription behavior.

## Patterns

### Listen to ignored keyboard events

```rust
use iced::keyboard;

fn subscription(_: &State) -> Subscription<Message> {
    keyboard::listen().map(Message::KeyboardEvent)
}
```

### Ctrl/Cmd+S as a shortcut using `COMMAND`

```rust
use iced::keyboard::{self, Key, Modifiers};

if let Event::Keyboard(keyboard::Event::KeyPressed {
    key: Key::Character(c),
    modifiers,
    ..
}) = event {
    if c.as_str() == "s" && modifiers.contains(Modifiers::COMMAND) {
        shell.publish(Message::Save);
        shell.capture_event();
    }
}
```

### Layout-independent WASD

```rust
use iced::keyboard::{self, key::{Physical, Code}};

if let Event::Keyboard(keyboard::Event::KeyPressed { physical_key, .. }) = event {
    match physical_key {
        Physical::Code(Code::KeyW) => { /* forward */ }
        Physical::Code(Code::KeyA) => { /* strafe left */ }
        Physical::Code(Code::KeyS) => { /* backward */ }
        Physical::Code(Code::KeyD) => { /* strafe right */ }
        _ => {}
    }
}
```

### Map Cyrillic to Latin via `to_latin`

```rust
use iced::keyboard::{Key, key::{Physical, Code}};

assert_eq!(
    Key::Character("с".into()).to_latin(Physical::Code(Code::KeyC)),
    Some('c'),
);
```

## Gotchas

- **`key` vs `modified_key` vs `physical_key`** distinguishes shortcut semantics: use `key` for the logical key, `modified_key` for the key with non-Ctrl modifiers applied, and `physical_key` for layout-independent bindings.
- `Modifiers::COMMAND` is the portable way to express "the primary modifier for keyboard shortcuts". `COMMAND` is the logo key on macOS and Ctrl elsewhere.
- `text` is `Option<SmolStr>` because a press may produce no text.
- `repeat` can fire many times for a held key — debounce in application state if your action should only happen once.
- `Key::Character(SmolStr)` may be a string with multiple Unicode scalar values.
- Handle `Key::Unidentified` explicitly when the application needs a fallback for an unrecognized key.
- No "just the pressed character" helper -- pattern-match on `Key::Character` explicitly.

## See also

- `mouse.md`
- `events.md`
- `subscription.md`
