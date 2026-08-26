# TextInput

> `iced::widget::text_input` · iced 0.14.0

A single-line text field. Use for search boxes, forms, credentials, URL fields. For multi-line editing, use `widget-text-editor.md` instead.

## API

### `TextInput` struct

```rust
pub struct TextInput<'a, Message, Theme = Theme, Renderer = Renderer<Renderer, Renderer>>
where
    Theme: Catalog,
    Renderer: Renderer,
{ /* private fields */ }

impl<'a, Message, Theme, Renderer> TextInput<'a, Message, Theme, Renderer>
where
    Message: Clone,
    Theme: Catalog,
    Renderer: Renderer,
{
    pub fn new(placeholder: &str, value: &str) -> Self;

    pub fn id(self, id: impl Into<Id>) -> Self;
    pub fn secure(self, is_secure: bool) -> Self;

    pub fn on_input(self, on_input: impl Fn(String) -> Message + 'a) -> Self;
    pub fn on_input_maybe(self, on_input: Option<impl Fn(String) -> Message + 'a>) -> Self;
    pub fn on_submit(self, message: Message) -> Self;
    pub fn on_submit_maybe(self, on_submit: Option<Message>) -> Self;
    pub fn on_paste(self, on_paste: impl Fn(String) -> Message + 'a) -> Self;
    pub fn on_paste_maybe(self, on_paste: Option<impl Fn(String) -> Message + 'a>) -> Self;

    pub fn font(self, font: <Renderer as Renderer>::Font) -> Self;
    pub fn icon(self, icon: Icon<<Renderer as Renderer>::Font>) -> Self;
    pub fn width(self, width: impl Into<Length>) -> Self;
    pub fn padding<P: Into<Padding>>(self, padding: P) -> Self;
    pub fn size(self, size: impl Into<Pixels>) -> Self;
    pub fn line_height(self, line_height: impl Into<LineHeight>) -> Self;
    pub fn align_x(self, alignment: impl Into<Horizontal>) -> Self;

    pub fn style(self, style: impl Fn(&Theme, Status) -> Style + 'a) -> Self
    where
        <Theme as Catalog>::Class<'a>: From<Box<dyn Fn(&Theme, Status) -> Style + 'a>>;

    pub fn class(self, class: impl Into<<Theme as Catalog>::Class<'a>>) -> Self;
}
```

### `Status` enum

```rust
pub enum Status {
    Active,
    Hovered,
    Focused { is_hovered: bool },
    Disabled,
}
```

### `Style` struct

```rust
pub struct Style {
    pub background: Background,
    pub border: Border,
    pub icon: Color,
    pub placeholder: Color,
    pub value: Color,
    pub selection: Color,
}
```

### `Icon` struct

```rust
pub struct Icon<Font> {
    pub font: Font,
    pub code_point: char,
    pub size: Option<Pixels>,
    pub spacing: f32,
    pub side: Side,
}
```

### `Side` enum

```rust
pub enum Side {
    Left,
    Right,
}
```

### `Value`, `State`, `Cursor` structs

Internal types available via `iced::widget::text_input::{Value, State, Cursor}`.
- `Value` — wraps the text content for cursor/selection computation.
- `State` — the internal focus/cursor state stored on `Tree`.
- `Cursor` — text cursor tracking (offset, selection range).

### `Catalog` trait

```rust
pub trait Catalog {
    type Class<'a>;
    fn default<'a>() -> Self::Class<'a>;
    fn style(&self, class: &Self::Class<'_>, status: Status) -> Style;
}
```

### Constants & type aliases

```rust
pub const DEFAULT_PADDING: Padding;
pub type StyleFn<'a, Theme> = Box<dyn Fn(&Theme, Status) -> Style + 'a>;
```

### Functions

```rust
pub fn text_input<'a, Message, Theme, Renderer>(
    placeholder: &str,
    value: &str,
) -> TextInput<'a, Message, Theme, Renderer>;

pub fn default(theme: &Theme, status: Status) -> Style;
```

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
use iced::Font;

text_input("Search...", &state.query)
    .on_input(Message::QueryChanged)
    .icon(text_input::Icon {
        font: Font::DEFAULT,
        code_point: '\u{F002}', // FontAwesome search glyph
        size: Some(16.0.into()),
        spacing: 8.0,
        side: text_input::Side::Left,
    })
```

### Programmatic focus via `id`

```rust
let search_id = text_input::Id::new("search");

text_input("...", &state.query)
    .id(search_id.clone())
    .on_input(Message::Query)

// Elsewhere, focus it:
Task::done(Message::Focus(search_id))
// In update: Task::focus(id)
```

## Gotchas

- Omitting `on_input` makes the input disabled (like `Button` without `on_press`). Use `on_input_maybe` for conditional enable — never wrap the widget.
- `on_submit` fires on Enter **only when the TextInput is focused**. Global Enter handling needs a subscription.
- `secure(true)` replaces each character with a mask glyph — the `Value` still holds the cleartext string, so treat it as sensitive.
- `on_paste` fires in addition to `on_input` when text is pasted — both will receive the new value if both are set. Use one or the other to avoid double-processing.
- `size()` sets the **font size in pixels** for displayed text. `padding()` sets the inner padding of the box.
- The `Focused { is_hovered }` variant lets style functions distinguish "focused and hovered" from "focused and mouse is elsewhere" — the default theme uses this for dual outline effects.

## See also

- `widget-text-editor.md` — multi-line text editing
- `widget-combo-box.md` — searchable dropdown (text input + menu)
- `catalog.md` — styling pattern
- `advanced-operation.md` — `Operation` for focus, selection, programmatic text changes
- `task.md` — `Task::focus(id)`, `Task::select_all(id)` for programmatic control
