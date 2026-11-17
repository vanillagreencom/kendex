# Lazy and keyed columns

> `iced::widget::lazy` + `iced::widget::keyed` · iced 0.14.0

Read when caching an expensive widget subtree or keeping list-item state associated with stable keys. The pinned [Lazy source] owns dependency hashing and subtree lifetimes. The [keyed column source] owns its constructors, builders and key bounds.

## Lazy subtrees

Enable the `lazy` feature. `lazy(dependency, view)` accepts a `Hash` dependency and a closure that builds the subtree. The widget builds the subtree initially and rebuilds it when the dependency hash changes. Include every value that changes the subtree in the dependency, or use a version that changes with those values.

The resulting subtree must convert into `Element<'static, ...>`. The dependency and closure may borrow application state, but widgets returned by the closure cannot retain those borrows. Build owned text or clone data into the returned widgets.

```rust
use iced::widget::{column, lazy, text};

lazy(&self.expensive_data, |data| {
    column(data.iter().map(|item| text(item.to_string()).into()))
})
```

Use the [Lazy source] and [lazy helper source] for exact generic bounds, including the `'static` message, theme, renderer and returned-view requirements for widget conversion. The enclosing lazy widget can still have a shorter lifetime.

## Keyed columns

`keyed::Column` associates children with keys during tree reconciliation. Use stable keys that are unique within the column, such as item IDs. Its widget implementation requires `Key: Copy + PartialEq + 'static`; `u64` or `usize` can serve as keys. Duplicate keys cannot distinguish item identity. A regular column reconciles by position, so inserts, removals and reorderings can associate state with a different item.

```rust
use iced::widget::{keyed, text};

keyed::Column::with_children(
    self.items.iter().map(|item| (item.id, text(&item.name).into()))
)
.spacing(4)
```

Use `new()` for an empty column, `with_capacity(...)` to reserve space or `with_children(...)` for keyed elements. `push(key, child)`, `push_maybe(key, option)` and `extend(...)` add keyed children. Conditional children keep their own stable keys:

```rust
let mut col = keyed::Column::new();
for item in &self.items {
    col = col.push_maybe(item.id, item.visible.then(|| text(&item.name)));
}
```

`from_vecs(keys, children)` accepts preallocated vectors. Keep corresponding keys and children together. This constructor does not infer sizing from children; set the column's width or height when a child uses `Fill`. The usual spacing, padding, width, height, maximum width and alignment builders are declared in the [keyed column source].

## See also

- [Responsive](widget-responsive.md): rebuilding from available size.
- [Widget tree](advanced-tree.md): reconciliation.
- [Animated layout](guide-animated-layout.md): keyed identity in layered and reordered views.
- [Widget catalog](widgets.md).

[Lazy source]: https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/lazy.rs
[lazy helper source]: https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/lazy/helpers.rs
[keyed column source]: https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/keyed/column.rs
