# TextEditor

> `iced::widget::text_editor` · iced 0.14.0

A multi-line text editor with cursor, selection, undo/redo, and optional syntax highlighting. Backed by cosmic-text. Use for code editors, long-form text entry, note-taking surfaces.

## API

### `TextEditor` struct

```rust
pub struct TextEditor<'a, Highlighter, Message, Theme = Theme, Renderer = Renderer<Renderer, Renderer>>
where
    Highlighter: Highlighter,
    Theme: Catalog,
    Renderer: Renderer,
{ /* private fields */ }

impl<'a, Message, Theme, Renderer> TextEditor<'a, PlainText, Message, Theme, Renderer>
where
    Theme: Catalog,
    Renderer: Renderer,
{
    pub fn new(content: &'a Content<Renderer>) -> Self;
    pub fn id(self, id: impl Into<Id>) -> Self;
}

impl<'a, Highlighter, Message, Theme, Renderer> TextEditor<'a, Highlighter, Message, Theme, Renderer>
where
    Highlighter: Highlighter,
    Theme: Catalog,
    Renderer: Renderer,
{
    pub fn placeholder(self, placeholder: impl IntoFragment<'a>) -> Self;
    pub fn width(self, width: impl Into<Pixels>) -> Self;
    pub fn height(self, height: impl Into<Length>) -> Self;
    pub fn min_height(self, min_height: impl Into<Pixels>) -> Self;
    pub fn max_height(self, max_height: impl Into<Pixels>) -> Self;

    pub fn on_action(self, on_edit: impl Fn(Action) -> Message + 'a) -> Self;

    pub fn font(self, font: impl Into<<Renderer as Renderer>::Font>) -> Self;
    pub fn size(self, size: impl Into<Pixels>) -> Self;
    pub fn line_height(self, line_height: impl Into<LineHeight>) -> Self;
    pub fn padding(self, padding: impl Into<Padding>) -> Self;
    pub fn wrapping(self, wrapping: Wrapping) -> Self;

    // Syntax highlighting (feature = "highlighter")
    pub fn highlight(self, syntax: &str, theme: Theme) -> Self
    where Renderer: Renderer<Font = Font>;

    pub fn highlight_with<H: Highlighter>(
        self,
        settings: H::Settings,
        to_format: fn(&H::Highlight, &Theme) -> Format<Renderer::Font>,
    ) -> TextEditor<'a, H, Message, Theme, Renderer>;

    pub fn key_binding(
        self,
        key_binding: impl Fn(KeyPress) -> Option<Binding<Message>> + 'a,
    ) -> Self;

    pub fn style(self, style: impl Fn(&Theme, Status) -> Style + 'a) -> Self;
    pub fn class(self, class: impl Into<<Theme as Catalog>::Class<'a>>) -> Self;
}
```

### `Content<R>` struct

```rust
pub struct Content<R = Renderer<Renderer, Renderer>>(/* private */)
where R: Renderer;

impl<R: Renderer> Content<R> {
    pub fn new() -> Content<R>;
    pub fn with_text(text: &str) -> Content<R>;

    pub fn perform(&mut self, action: Action);
    pub fn move_to(&mut self, cursor: Cursor);
    pub fn cursor(&self) -> Cursor;

    pub fn line_count(&self) -> usize;
    pub fn line(&self, index: usize) -> Option<Line<'_>>;
    pub fn lines(&self) -> impl Iterator<Item = Line<'_>>;
    pub fn text(&self) -> String;
    pub fn selection(&self) -> Option<String>;
    pub fn line_ending(&self) -> Option<LineEnding>;
    pub fn is_empty(&self) -> bool;
}
```

### `Action` enum

```rust
pub enum Action {
    Move(Motion),
    Select(Motion),
    SelectWord,
    SelectLine,
    SelectAll,
    Edit(Edit),
    Click(Point),
    Drag(Point),
    Scroll { lines: i32 },
}

impl Action {
    pub fn is_edit(&self) -> bool; // feature = "advanced"
}
```

### `Edit` enum

```rust
pub enum Edit {
    Insert(char),
    Paste(Arc<String>),
    Enter,
    Indent,
    Unindent,
    Backspace,
    Delete,
}
```

### `Motion` enum

```rust
pub enum Motion {
    Left, Right, Up, Down,
    WordLeft, WordRight,
    Home, End,
    PageUp, PageDown,
    DocumentStart, DocumentEnd,
}
```

### `Direction` enum

```rust
pub enum Direction {
    Left,
    Right,
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
    pub placeholder: Color,
    pub value: Color,
    pub selection: Color,
}
```

### `Binding<Message>` + `KeyPress`

```rust
pub enum Binding<Message> {
    Unfocus,
    Copy,
    Cut,
    Paste,
    Move(Motion),
    Select(Motion),
    SelectWord,
    SelectLine,
    SelectAll,
    Insert(char),
    Enter,
    Indent,
    Unindent,
    Backspace,
    Delete,
    Sequence(Vec<Binding<Message>>),
    Custom(Message),
}

pub struct KeyPress {
    pub key: Key,
    pub modifiers: Modifiers,
    pub text: Option<SmolStr>,
    pub status: Status,
}
```

### `Catalog` trait

```rust
pub trait Catalog {
    type Class<'a>;
    fn default<'a>() -> Self::Class<'a>;
    fn style(&self, class: &Self::Class<'_>, status: Status) -> Style;
}
```

### Functions & type aliases

```rust
pub fn text_editor<'a, Message, Theme, Renderer>(
    content: &'a Content<Renderer>,
) -> TextEditor<'a, PlainText, Message, Theme, Renderer>;

pub fn default(theme: &Theme, status: Status) -> Style;

// feature = "highlighter"
pub fn highlight(syntax: &str, theme: Theme) -> ...;

pub type StyleFn<'a, Theme> = Box<dyn Fn(&Theme, Status) -> Style + 'a>;
```

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
        if press.modifiers.command() && press.key.to_latin(/*...*/) == Some('s') {
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
