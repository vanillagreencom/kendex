# Lazy & Keyed Column

> `iced::widget::lazy` + `iced::widget::keyed` · iced 0.14.0

`Lazy` caches a widget subtree and only rebuilds when its dependency changes. `keyed::Column` is a column where each child has a stable key for efficient diffing when items are inserted, removed, or reordered.

## API

### `Lazy` struct

```rust
pub struct Lazy<'a, Message, Theme, Renderer, Dependency, View>
where
    Dependency: Hash + 'a,
    View: Into<Element<'static, Message, Theme, Renderer>> + 'static,
{ /* private fields */ }

impl<'a, Message, Theme, Renderer, Dependency, View>
    Lazy<'a, Message, Theme, Renderer, Dependency, View>
where
    Dependency: Hash + 'a,
    View: Into<Element<'static, Message, Theme, Renderer>> + 'static,
    Message: 'static,
    Theme: 'static,
    Renderer: Renderer + 'static,
{
    pub fn new(
        dependency: Dependency,
        view: impl Fn(&Dependency) -> View + 'a,
    ) -> Self;
}
```

### `lazy` function

```rust
pub fn lazy<'a, Message, Theme, Renderer, Dependency, View>(
    dependency: Dependency,
    view: impl Fn(&Dependency) -> View + 'a,
) -> Lazy<'a, Message, Theme, Renderer, Dependency, View>
where
    Dependency: Hash + 'a,
    View: Into<Element<'static, Message, Theme, Renderer>> + 'static,
    Message: 'static,
    Theme: 'static,
    Renderer: Renderer + 'static;
```

### `keyed::Column` struct

```rust
pub struct Column<'a, Key, Message, Theme = Theme, Renderer = Renderer<Renderer, Renderer>>
where
    Key: Copy + PartialEq,
{ /* private fields */ }

impl<'a, Key, Message, Theme, Renderer> Column<'a, Key, Message, Theme, Renderer>
where
    Key: Copy + PartialEq + 'static,
    Renderer: Renderer,
{
    pub fn new() -> Self;
    pub fn with_children(
        children: impl IntoIterator<Item = (Key, Element<'a, Message, Theme, Renderer>)>,
    ) -> Self;
    pub fn with_capacity(capacity: usize) -> Self;
    pub fn from_vecs(
        keys: Vec<Key>,
        children: Vec<Element<'a, Message, Theme, Renderer>>,
    ) -> Self;

    pub fn push(
        self,
        key: Key,
        child: impl Into<Element<'a, Message, Theme, Renderer>>,
    ) -> Self;
    pub fn push_maybe(
        self,
        key: Key,
        child: Option<impl Into<Element<'a, Message, Theme, Renderer>>>,
    ) -> Self;
    pub fn extend(
        self,
        children: impl IntoIterator<Item = (Key, Element<'a, Message, Theme, Renderer>)>,
    ) -> Self;

    pub fn spacing(self, amount: impl Into<Pixels>) -> Self;
    pub fn padding<P: Into<Padding>>(self, padding: P) -> Self;
    pub fn width(self, width: impl Into<Length>) -> Self;
    pub fn height(self, height: impl Into<Length>) -> Self;
    pub fn max_width(self, max_width: impl Into<Pixels>) -> Self;
    pub fn align_items(self, align: Alignment) -> Self;
}
```

## Patterns

### Lazy: skip rebuild when data unchanged

```rust
use iced::widget::lazy;

lazy(&self.expensive_data, |data| {
    // This closure only runs when `data` hash changes
    column(data.iter().map(|item| text(item).into())).into()
})
```

### Keyed column: stable identity for list items

```rust
use iced::widget::keyed;

keyed::Column::with_children(
    self.items.iter().map(|item| {
        (item.id, text(&item.name).into())
    })
)
.spacing(4)
```

### Keyed column with conditional items

```rust
let mut col = keyed::Column::new();
for item in &self.items {
    col = col.push_maybe(
        item.id,
        item.visible.then(|| text(&item.name).into()),
    );
}
```

## Gotchas

- `Lazy` requires `Dependency: Hash`. The widget tree is rebuilt only when the dependency's hash changes. Use a version counter or content hash as the dependency.
- `Lazy` produces `Element<'static, ...>` -- the view closure cannot borrow from `self`. Clone or move data into the closure.
- `keyed::Column` requires `Key: Copy + PartialEq + 'static`. Use simple types like `u64` or `usize` as keys.
- Keys must be unique within a single `keyed::Column`. Duplicate keys cause incorrect diffing.
- For non-keyed lists, a regular `column` re-diffs by index position, which breaks widget state when items are reordered.

## See also

- `widget-responsive.md` -- rebuilds based on available size
- `advanced-tree.md` -- `Tree` diffing that keyed columns optimize
- `guide-animated-layout.md` -- keyed identity in reordered/layered views
- `widgets.md` -- widget catalog
