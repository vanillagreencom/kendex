# Sensor

> `iced::widget::sensor` · iced 0.14.0

Detects when content pops in and out of view and when it changes size. Ideal for lazy loading in scrollable lists, measuring widget dimensions, and visibility-triggered actions.

## API

### `Sensor` struct

```rust
pub struct Sensor<'a, Key, Message, Theme = Theme, Renderer = Renderer<Renderer, Renderer>>
where
    Key: Key,
    Renderer: Renderer,
{ /* private fields */ }

impl<'a, Key, Message, Theme, Renderer> Sensor<'a, Key, Message, Theme, Renderer>
where
    Key: Key,
    Renderer: Renderer,
{
    pub fn new(
        content: impl Into<Element<'a, Message, Theme, Renderer>>,
    ) -> Sensor<'a, (), Message, Theme, Renderer>;

    pub fn on_show(
        self,
        on_show: impl Fn(Size) -> Message + 'a,
    ) -> Self;

    pub fn on_resize(
        self,
        on_resize: impl Fn(Size) -> Message + 'a,
    ) -> Self;

    pub fn on_hide(self, on_hide: Message) -> Self;

    pub fn key<K>(
        self,
        key: K,
    ) -> Sensor<'a, impl Key, Message, Theme, Renderer>
    where
        K: Clone + PartialEq + 'static;

    pub fn key_ref<K>(
        self,
        key: &'a K,
    ) -> Sensor<'a, &'a K, Message, Theme, Renderer>
    where
        K: ToOwned + PartialEq<<K as ToOwned>::Owned> + ?Sized,
        <K as ToOwned>::Owned: 'static;

    pub fn anticipate(
        self,
        distance: impl Into<Pixels>,
    ) -> Self;

    pub fn delay(
        self,
        delay: impl Into<Duration>,
    ) -> Self;
}
```

### Functions

```rust
pub fn sensor<'a, Message, Theme, Renderer>(
    content: impl Into<Element<'a, Message, Theme, Renderer>>,
) -> Sensor<'a, (), Message, Theme, Renderer>
where
    Renderer: Renderer;
```

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
- `on_resize` fires only while the content is already visible and its size changes. It does not fire on initial show -- use `on_show` for that.
- `anticipate(distance)` triggers `on_show`/`on_hide` when the content is within `distance` pixels of the viewport edge, enabling pre-loading.
- `key` provides continuity: if the key changes, the sensor re-triggers as if the content disappeared and reappeared.
- `delay` debounces show/hide events. Combined with `key`, this prevents rapid-fire triggers during fast scrolling or typing.

## See also

- `widget-scrollable.md` -- sensors are commonly used inside scrollables
- `widget-responsive.md` -- size-aware widget building
- `widget-lazy-keyed.md` -- `Lazy` for caching, `keyed::Column` for stable diffing
- `widgets.md` -- widget catalog
