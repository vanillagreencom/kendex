# Responsive

> `iced::widget::responsive` · iced 0.14.0

A widget that receives its available size and can conditionally build different content based on that size. Always tries to fill all available space by default.

## API

Iced 0.14.0 owns the declarations, bounds, feature gates and defaults: [widget/src/responsive.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/responsive.rs); [widget/src/helpers.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/helpers.rs).

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
- The `view` closure runs during layout. Capture application state in the closure; the `Size` argument comes from the layout limits.
- Avoid expensive computation inside the `view` closure -- it runs on every layout pass. Use `lazy` wrapping if the content only depends on a hashable subset of state.
- The `Size` parameter is the maximum available space, not the final rendered size.

## See also

- `widget-sensor.md` -- observe actual rendered size (post-layout)
- `widget-lazy-keyed.md` -- `Lazy` for caching expensive subtrees
- `advanced-layout.md` -- `Limits` that drive the size calculation
- `widgets.md` -- widget catalog
