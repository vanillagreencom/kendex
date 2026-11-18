# Sensor

> `iced::widget::sensor` · iced 0.14.0

Detects when content pops in and out of view and when it changes size. Use for lazy loading in scrollable lists, measuring widget dimensions, and visibility-triggered actions.

## API

Iced 0.14.0 owns the declarations, bounds, feature gates and defaults: [widget/src/sensor.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/sensor.rs); [widget/src/helpers.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/helpers.rs).

## Patterns

### Measure content size

```rust
use iced::widget::{sensor, text};
use iced::Size;

sensor(text("Measure me!"))
    .on_resize(Message::SizeChanged)

// In update:
Message::SizeChanged(size) => {
    self.content_size = Some(size);
}
```

### Lazy loading in a scrollable

```rust
use iced::widget::sensor;

sensor(placeholder_or_content)
    .on_show(|_size| Message::LoadItem(item_id))
    .on_hide(Message::UnloadItem(item_id))
    .anticipate(200) // start loading 200px before visible
    .key(item_id)
```

### Debounce rapid key changes

```rust
use std::time::Duration;

sensor(content)
    .key(search_query.clone())
    .on_show(|size| Message::QueryVisible(size))
    .delay(Duration::from_millis(300))
```

## Gotchas

- `on_show` fires when the content becomes visible in the viewport. It receives the `Size` of the content at that moment.
- With `on_show` set, `on_resize` reports size changes after showing. Without `on_show`, `on_resize` also reports the initial size and does not gate notifications on visibility.
- `anticipate(distance)` triggers `on_show`/`on_hide` when the content is within `distance` pixels of the viewport edge, enabling pre-loading.
- `key` provides continuity: if the key changes, the sensor re-triggers as if the content disappeared and reappeared.
- `delay` debounces show/hide events. Combined with `key`, this prevents rapid-fire triggers during fast scrolling or typing.

## See also

- `widget-scrollable.md` -- sensors are commonly used inside scrollables
- `widget-responsive.md` -- size-aware widget building
- `widget-lazy-keyed.md` -- `Lazy` for caching, `keyed::Column` for stable diffing
- `widgets.md` -- widget catalog
