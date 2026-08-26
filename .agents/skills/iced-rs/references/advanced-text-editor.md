# Text Editor (advanced)

> `iced::advanced::text::editor` · iced 0.14.0

Low-level traits and types for multi-line text editing. The `Editor` trait is the backend contract that `widget::text_editor` delegates to; use these types when building custom editor widgets or intercepting editor actions programmatically.

## API

### `Editor` trait

```rust
pub trait Editor: Sized + Default {
    type Font: Copy + PartialEq + Default;

    fn with_text(text: &str) -> Self;
    fn is_empty(&self) -> bool;
    fn cursor(&self) -> Cursor;
    fn selection(&self) -> Selection;
    fn copy(&self) -> Option<String>;
    fn line(&self, index: usize) -> Option<Line<'_>>;
    fn line_count(&self) -> usize;
    fn perform(&mut self, action: Action);
    fn move_to(&mut self, cursor: Cursor);
    fn bounds(&self) -> Size;
    fn min_bounds(&self) -> Size;
    fn update(
        &mut self,
        new_bounds: Size,
        new_font: Self::Font,
        new_size: Pixels,
        new_line_height: LineHeight,
        new_wrapping: Wrapping,
        new_highlighter: &mut impl Highlighter,
    );
    fn highlight<H: Highlighter>(
        &mut self,
        font: Self::Font,
        highlighter: &mut H,
        format_highlight: impl Fn(&H::Highlight) -> Format<Self::Font>,
    );
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
    pub fn is_edit(&self) -> bool;
}
```

- **`Move(Motion)`** -- move cursor without selecting.
- **`Select(Motion)`** -- extend selection in the given direction.
- **`SelectWord` / `SelectLine` / `SelectAll`** -- expand selection to word, line, or all.
- **`Edit(Edit)`** -- mutating text operation (insert, delete, paste, etc.).
- **`Click(Point)` / `Drag(Point)`** -- mouse interaction in widget-local coords.
- **`Scroll { lines }`** -- scroll by N lines (positive = down).

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

### `Cursor` struct

```rust
pub struct Cursor {
    pub position: Position,
    pub selection: Option<Position>,
}
```

### `Position` struct

```rust
pub struct Position {
    pub line: usize,
    pub column: usize,
}
```

### `Selection` enum

```rust
pub enum Selection {
    Caret(Point),
    Range(Vec<Rectangle>),
}
```

### `Line` struct

```rust
pub struct Line<'a> {
    pub text: Cow<'a, str>,
    pub ending: LineEnding,
}
```

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
fn handle_action(action: Action) {
    if action.is_edit() {
        // Mark document as dirty
    }
    content.perform(action);
}
```

### Read selected text

```rust
if let Some(selected) = editor.copy() {
    clipboard.write(selected);
}
```

## Gotchas

- `Action::is_edit()` requires the `advanced` feature flag.
- `Click` and `Drag` take widget-local `Point` coordinates, not window-global.
- `Scroll { lines }` uses positive-down convention; negative scrolls up.
- `Edit::Paste` wraps content in `Arc<String>` for cheap cloning across the event pipeline.
- `Cursor.selection` is `None` when there is no active selection (caret-only).

## See also

- `widget-text-editor.md` -- the high-level `TextEditor` widget that wraps this trait
- `advanced-text-highlighter.md` -- `Highlighter` trait used by `Editor::highlight`
- `advanced-text.md` -- `text::Renderer`, `Paragraph`, `Shaping`
- `keyboard.md` -- key events that map to `Motion` / `Edit` actions
