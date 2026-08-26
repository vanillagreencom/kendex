# Responsive

> `iced::widget::responsive` · iced 0.14.0

A widget that receives its available size and can conditionally build different content based on that size. Always tries to fill all available space by default.

## API

### `Responsive` struct

```rust
pub struct Responsive<'a, Message, Theme = Theme, Renderer = Renderer<Renderer, Renderer>>
{ /* private fields */ }

impl<'a, Message, Theme, Renderer> Responsive<'a, Message, Theme, Renderer>
where
    Renderer: Renderer,
{
    pub fn new(
        view: impl Fn(Size) -> Element<'a, Message, Theme, Renderer> + 'a,
    ) -> Self;

    pub fn width(self, width: impl Into<Length>) -> Self;
    pub fn height(self, height: impl Into<Length>) -> Self;
}
```

### Functions

```rust
pub fn responsive<'a, Message, Theme, Renderer>(
    view: impl Fn(Size) -> Element<'a, Message, Theme, Renderer> + 'a,
) -> Responsive<'a, Message, Theme, Renderer>
where
    Renderer: Renderer;
```

## Patterns

### Responsive layout (sidebar vs. stacked)

```rust
use iced::widget::responsive;
use iced::Size;

responsive(|size: Size| {
    if size.width > 600.0 {
        row![sidebar(), main_content()].into()
    } else {
        column![sidebar(), main_content()].into()
    }
})
```

### Adapt font size to available space

```rust
responsive(|size| {
    let font_size = if size.width > 800.0 { 18.0 } else { 14.0 };
    text("Adaptive text").size(font_size).into()
})
```

### Constrain responsive dimensions

```rust
responsive(|size| build_content(size))
    .width(Length::Fill)
    .height(Length::Fixed(400.0))
```

## Gotchas

- `Responsive` fills all available parent space by default. If the parent has unbounded space (e.g., inside a `Shrink` column), the `Size` received will be very large. Set explicit `width`/`height` to constrain it.
- The `view` closure is called during layout, not during `view()`. This means it cannot directly access `&self` from your application state. Pass state through captures.
- Avoid expensive computation inside the `view` closure -- it runs on every layout pass. Use `lazy` wrapping if the content only depends on a hashable subset of state.
- The `Size` parameter is the maximum available space, not the final rendered size.

## See also

- `widget-sensor.md` -- observe actual rendered size (post-layout)
- `widget-lazy-keyed.md` -- `Lazy` for caching expensive subtrees
- `advanced-layout.md` -- `Limits` that drive the size calculation
- `widgets.md` -- widget catalog
