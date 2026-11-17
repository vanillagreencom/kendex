# TextInput

> `iced::widget::text_input` · iced 0.14.0

A single-line text field. Use for search boxes, forms, credentials, URL fields. For multi-line editing, use `widget-text-editor.md` instead.

## API

Iced 0.14.0 owns the declarations, bounds, feature gates and defaults: [widget/src/text_input.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/text_input.rs); [widget/src/helpers.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/helpers.rs).

## Patterns

### Basic field

```rust
use iced::widget::text_input;

text_input("Type something...", &state.content)
    .on_input(Message::ContentChanged)
```

### With submit (Enter)

```rust
text_input("Search", &state.query)
    .on_input(Message::QueryChanged)
    .on_submit(Message::Search)
    .padding(10)
    .size(20)
```

### Password field

```rust
text_input("Password", &state.password)
    .secure(true)
    .on_input(Message::PasswordChanged)
```

### With search icon

```rust
use iced::widget::text_input;
// state.icon_font is a loaded font containing the search glyph.

text_input("Search...", &state.query)
    .on_input(Message::QueryChanged)
    .icon(text_input::Icon {
        font: state.icon_font,
        code_point: '\u{F002}', // FontAwesome search glyph
        size: Some(16.0.into()),
        spacing: 8.0,
        side: text_input::Side::Left,
    })
```

### Programmatic focus via `id`

```rust
let search_id = iced::widget::Id::new("search");

text_input("...", &state.query)
    .id(search_id.clone())
    .on_input(Message::Query)

```

In `update`, return the focus task:

```rust
iced::widget::operation::focus(search_id)
```

## Gotchas

- Omitting `on_input` makes the input disabled (like `Button` without `on_press`). Use `on_input_maybe` for conditional enable — never wrap the widget.
- `on_submit` fires on Enter **only when the TextInput is focused**. Global Enter handling needs a subscription.
- `secure(true)` replaces each character with a mask glyph — the `Value` still holds the cleartext string, so treat it as sensitive.
- On paste, `on_paste` receives the updated value when configured; otherwise `on_input` receives it. The widget still requires `on_input` to be enabled.
- `size()` sets the **font size in pixels** for displayed text. `padding()` sets the inner padding of the box.
- The `Focused { is_hovered }` variant lets style functions distinguish "focused and hovered" from "focused and mouse is elsewhere" — the default theme uses this for dual outline effects.

## See also

- `widget-text-editor.md` — multi-line text editing
- `widget-combo-box.md` — searchable dropdown (text input + menu)
- `catalog.md` — styling pattern
- `advanced-operation.md` — `Operation` for focus, selection, programmatic text changes
- `task.md` — `iced::widget::operation::focus(id)`, `select_all(id)` for programmatic control
