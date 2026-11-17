# TextEditor

> `iced::widget::text_editor` · iced 0.14.0

A multi-line text editor with cursor, selection and optional syntax highlighting. Backed by cosmic-text. Use for code editors, long-form text entry, note-taking surfaces.

## API

Iced 0.14.0 owns the declarations, bounds, feature gates and defaults: [widget/src/text_editor.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/text_editor.rs); [widget/src/helpers.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/helpers.rs).

## Patterns

### Basic multi-line editor

```rust
use iced::widget::text_editor;

struct State {
    content: text_editor::Content,
}

impl State {
    fn new() -> Self {
        Self { content: text_editor::Content::with_text("Hello\nWorld") }
    }
}

#[derive(Debug, Clone)]
enum Message {
    Edit(text_editor::Action),
}

fn view(state: &State) -> Element<'_, Message> {
    text_editor(&state.content)
        .placeholder("Type something here...")
        .on_action(Message::Edit)
        .into()
}

fn update(state: &mut State, message: Message) {
    match message {
        Message::Edit(action) => state.content.perform(action),
    }
}
```

### Syntax-highlighted code editor (feature `highlighter`)

```rust
text_editor(&state.content)
    .on_action(Message::Edit)
    .font(Font::MONOSPACE)
    .highlight("rs", state.highlighter_theme.clone())
```

### Custom keybinding — Ctrl+S as Save

```rust
use iced::widget::text_editor::{self, Binding, KeyPress};

text_editor(&state.content)
    .on_action(Message::Edit)
    .key_binding(|press: KeyPress| {
        if press.modifiers.command() && press.key.as_ref() == iced::keyboard::Key::Character("s") {
            Some(Binding::Custom(Message::Save))
        } else {
            text_editor::Binding::from_key_press(press) // fallthrough to default
        }
    })
```

## Gotchas

- **`Content` is not in widget Tree state** — it lives in your application `State`. Clone/mutate it outside the view. Call `content.perform(action)` in your update handler.
- The `on_action` closure converts `Action -> Message`. Your `update` then calls `state.content.perform(action)` to apply it. This indirection lets you intercept/transform actions.
- `Action::Edit(Edit::Insert('a'))` is what arrives per character typed — not a full `String`. Concatenation happens via successive inserts.
- `Action::Click`/`Drag` receive widget-local coordinates — use for custom hit-testing.
- Use `.min_height(...)` and `.max_height(...)` for auto-grow editors that expand up to a cap.
- `highlight()` requires the `highlighter` feature. For custom highlighting, use `highlight_with(<H: Highlighter>)` and supply your own highlighter.
- `Content::text()` allocates a fresh `String` — cache the result if you need it frequently (dirty-tracking, syntax re-parsing).

## See also

- `widget-text-input.md` — single-line alternative
- `advanced-text-editor.md` — `Action`, `Edit`, `Motion` from `iced::advanced::text::editor`
- `advanced-text-highlighter.md` — custom highlighter implementation
- `catalog.md` — styling pattern
- `keyboard.md` — for custom key bindings
