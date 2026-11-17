# Text Editor (advanced)

> `iced::advanced::text::editor` · iced 0.14.0

Low-level traits and types for multi-line text editing. The `Editor` trait is the backend contract that `widget::text_editor` delegates to; use these types when building custom editor widgets or intercepting editor actions programmatically.

Read when implementing or debugging text editor behavior in a custom widget or backend. Enable Iced’s `advanced` feature for the `iced::advanced` paths used here.

## Declarations

Pinned Iced 0.14.0 declarations, signatures, defaults and implementation:

- [core/src/text/editor.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/text/editor.rs).
- [widget/src/text_editor.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/text_editor.rs).

## Patterns

### Perform an action on a text editor

```rust
use iced::advanced::text::editor::{Action, Edit, Motion};

// Move cursor to end of document
editor.perform(Action::Move(Motion::DocumentEnd));

// Insert a character
editor.perform(Action::Edit(Edit::Insert('x')));

// Select current line, then delete
editor.perform(Action::SelectLine);
editor.perform(Action::Edit(Edit::Delete));
```

### Check if action is an edit (mutation)

```rust
fn handle_action(content: &mut iced::widget::text_editor::Content, action: Action) {
    if action.is_edit() {
        // Mark document as dirty
    }
    content.perform(action);
}
```

### Read selected text

```rust
if let Some(selected) = editor.copy() {
    clipboard.write(iced::advanced::clipboard::Kind::Standard, selected);
}
```

## Gotchas

- `Action::is_edit()` tests whether the action is `Edit(_)`; it does not require `advanced` when reached through `iced::widget::text_editor::Action`.
- `Click` and `Drag` take widget-local `Point` coordinates, not window-global.
- `Scroll { lines }` uses positive-down convention; negative scrolls up.
- `Edit::Paste` wraps content in `Arc<String>` for cheap cloning across the event pipeline.
- `Cursor.selection` is `None` when there is no active selection (caret-only).

## See also

- `widget-text-editor.md` -- the high-level `TextEditor` widget that wraps this trait
- `advanced-text-highlighter.md` -- `Highlighter` trait used by `Editor::highlight`
- `advanced-text.md` -- `text::Renderer`, `Paragraph`, `Shaping`
- `keyboard.md` -- key events that map to `Motion` / `Edit` actions
