# Markdown

> `iced::widget::markdown` · iced 0.14.0 · feature = `markdown`

Read when displaying Markdown, handling its links or customizing its widgets. The pinned [Markdown source] owns parsing, items, settings, styles and viewer contracts. The bundled [Markdown example](../examples/markdown/src/main.rs) shows custom image rendering and link messages.

## Parsing and display

`markdown::parse(text)` returns an iterator of `Item`. Collect the items into state when the text changes, then pass references to `markdown::view`. Avoid parsing unchanged text on every view call. `Item` is a public enum; consult the source for its variants instead of treating it as opaque.

```rust
use iced::widget::markdown;

struct State {
    items: Vec<markdown::Item>,
}

#[derive(Debug, Clone)]
enum Message {
    LinkClicked(markdown::Uri),
}

impl State {
    fn new() -> Self {
        Self {
            items: markdown::parse("This is **bold** and *italic*!").collect(),
        }
    }

    fn view(&self) -> iced::Element<'_, Message> {
        markdown::view(&self.items, iced::Theme::TokyoNight)
            .map(Message::LinkClicked)
    }
}
```

`view` emits `markdown::Uri` link messages. Map them into the application's message type and handle navigation in `update`; rendering does not open links. `markdown::Content::parse(text)` is an alternative state container, with `items()` for display and `push_str(...)` for streamed Markdown.

## Settings and style

Use a `Theme` or `&Theme` as the settings argument, or construct `Settings::with_style(...)` or `Settings::with_text_size(...)`:

```rust
let settings = markdown::Settings::with_text_size(16, &theme);
markdown::view(&items, settings).map(Message::LinkClicked)
```

`with_text_size` sets heading sizes to 2, 1.75, 1.5, 1.25, 1 and 1 times the base size for levels 1 through 6. Adjust the public heading fields for other sizes. `Settings` also holds code size, spacing and `Style`; `Style` supplies text and code fonts, inline-code highlighting, padding and colors, and link color. The [Markdown source] owns their complete fields and defaults.

## Custom viewers

Use `view_with(items, settings, &viewer)` to customize rendering. `Viewer::on_link_click(Uri)` supplies the application's message, and the trait provides methods for individual Markdown elements. `items(&viewer, settings, slice)` also renders a slice with a custom viewer.

The theme's `markdown::Catalog` combines the widget catalogs Markdown uses and supplies the code-block class; it is not a standalone `Style` lookup catalog. Consult the source for its supertraits and method signature.

## See also

- [Text editor](widget-text-editor.md): editing text.
- [Theme](theme.md): theme settings.
- [Element](element.md): mapping messages.
- [Widget catalog](widgets.md).

[Markdown source]: https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/markdown.rs
