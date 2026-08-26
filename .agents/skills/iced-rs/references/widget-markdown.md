# Markdown

> `iced::widget::markdown` · iced 0.14.0 · feature = `markdown`

Renders Markdown content as native iced widgets. Parses Markdown text into `Item`s, then displays them via `view` or `items`. Link clicks produce `String` (URL) messages.

## API

### Parsing

```rust
pub fn parse(markdown: &str) -> impl Iterator<Item = Item> + '_;
```

### Display functions

```rust
pub fn view<'a, Theme, Renderer>(
    items: impl IntoIterator<Item = &'a Item>,
    settings: impl Into<Settings>,
) -> Element<'a, String, Theme, Renderer>
where
    Theme: Catalog + 'a,
    Renderer: Renderer<Font = Font> + 'a;

pub fn items<'a, Message, Theme, Renderer>(
    viewer: &impl Viewer<'a, Message, Theme, Renderer>,
    settings: Settings,
    items: &'a [Item],
) -> Element<'a, Message, Theme, Renderer>
where
    Message: 'a,
    Theme: Catalog + 'a,
    Renderer: Renderer<Font = Font> + 'a;
```

### `Item` enum

```rust
pub enum Item {
    // Opaque -- variants not publicly documented.
    // Produced by `parse()`, consumed by `view()` / `items()`.
}
```

### `Settings` struct

```rust
pub struct Settings {
    pub text_size: Pixels,
    pub h1_size: Pixels,
    pub h2_size: Pixels,
    pub h3_size: Pixels,
    pub h4_size: Pixels,
    pub h5_size: Pixels,
    pub h6_size: Pixels,
    pub code_size: Pixels,
    pub spacing: Pixels,
    pub style: Style,
}

impl Settings {
    pub fn with_style(style: impl Into<Style>) -> Settings;
    pub fn with_text_size(
        text_size: impl Into<Pixels>,
        style: impl Into<Style>,
    ) -> Settings;
}

impl From<&Theme> for Settings {}
impl From<Theme> for Settings {}
```

### `Style` struct

```rust
pub struct Style {
    pub font: Font,
    pub inline_code_highlight: Highlight,
    pub inline_code_padding: Padding,
    pub inline_code_color: Color,
    pub inline_code_font: Font,
    pub code_block_font: Font,
    pub link_color: Color,
}
```

### `Viewer` trait

```rust
pub trait Viewer<'a, Message, Theme, Renderer> {
    // Allows custom message types for link clicks.
    // Implement to map URL strings into your own Message type.
}
```

### `Catalog` trait

```rust
pub trait Catalog {
    type Class<'a>;
    fn default<'a>() -> Self::Class<'a>;
    fn style(&self, class: &Self::Class<'_>) -> Style;
}
```

## Patterns

### Basic markdown display

```rust
use iced::widget::markdown;

struct State {
    items: Vec<markdown::Item>,
}

impl State {
    fn new() -> Self {
        Self {
            items: markdown::parse("This is **bold** and *italic*!").collect(),
        }
    }

    fn view(&self) -> Element<'_, Message> {
        markdown::view(&self.items, Theme::TokyoNight)
            .map(Message::LinkClicked)
            .into()
    }
}
```

### Custom text sizes

```rust
let settings = markdown::Settings::with_text_size(16, &theme);
markdown::view(&items, settings).map(Message::LinkClicked)
```

### Handle link clicks

```rust
#[derive(Debug, Clone)]
enum Message {
    LinkClicked(String), // receives the URL
}

fn update(state: &mut State, message: Message) {
    match message {
        Message::LinkClicked(url) => {
            println!("Navigating to: {url}");
        }
    }
}
```

## Gotchas

- Requires the `markdown` crate feature to be enabled.
- `parse()` returns an iterator -- collect it into a `Vec<Item>` and store in state. Re-parsing on every `view()` call is wasteful.
- The simple `view()` function produces `Element<'a, String, ...>` -- link clicks emit raw URL strings. Use `.map(Message::LinkClicked)` to wrap them.
- Heading sizes auto-scale from `text_size`: h1 = 2x base, each subsequent level 25% smaller.

## See also

- `widget-text-editor.md` -- editable rich text
- `theme.md` -- `Theme` converts into `Settings` via `From`
- `element.md` -- `.map()` for message type conversion
- `widgets.md` -- widget catalog
