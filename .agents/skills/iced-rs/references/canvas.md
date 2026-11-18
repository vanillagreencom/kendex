# Canvas

> `iced::widget::canvas` · iced 0.14.0

Implement `canvas::Program<Message>` for 2D drawing. Use `Frame` for shapes and text. Image drawing also depends on renderer support and features. Enable the `canvas` feature.

Read when implementing Canvas drawing, state, or event handling.

## API

Read the [Iced 0.14.0 declarations](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/canvas.rs) for the widget, the [Program contract](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/canvas/program.rs) for callbacks, and [Frame declarations](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/graphics/src/geometry/frame.rs) for drawing operations. See the [cache declarations](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/graphics/src/geometry/cache.rs) for retained geometry.

## Patterns

### Draw a circle

```rust
use iced::mouse;
use iced::widget::canvas;
use iced::{Color, Element, Rectangle, Renderer, Theme};

#[derive(Debug)]
struct Circle {
    radius: f32,
}

impl<Message> canvas::Program<Message> for Circle {
    type State = ();

    fn draw(
        &self,
        _state: &(),
        renderer: &Renderer,
        _theme: &Theme,
        bounds: Rectangle,
        _cursor: mouse::Cursor,
    ) -> Vec<canvas::Geometry> {
        let mut frame = canvas::Frame::new(renderer, bounds.size());
        let circle = canvas::Path::circle(frame.center(), self.radius);
        frame.fill(&circle, Color::BLACK);
        vec![frame.into_geometry()]
    }
}

fn view<'a, Message: 'a>(_state: &'a State) -> Element<'a, Message> {
    canvas(Circle { radius: 50.0 }).into()
}
```

### Use a cache for stable layers

```rust
struct Chart {
    grid: canvas::Cache,
    series: canvas::Cache,
}

impl<Message> canvas::Program<Message> for Chart {
    type State = ();

    fn draw(&self, _state: &(), renderer: &Renderer, _theme: &Theme, bounds: Rectangle, _cursor: mouse::Cursor) -> Vec<canvas::Geometry> {
        let grid = self.grid.draw(renderer, bounds.size(), |frame| {
            // paint the grid once
        });

        let series = self.series.draw(renderer, bounds.size(), |frame| {
            // paint the data series (clear the cache when data changes)
        });

        vec![grid, series]
    }
}
```

### Save and restore transforms

```rust
frame.with_save(|frame| {
    frame.translate(Vector::new(50.0, 50.0));
    frame.rotate(std::f32::consts::PI / 4.0);
    frame.fill_rectangle(Point::ORIGIN, Size::new(20.0, 20.0), Color::WHITE);
});
// Frame transforms are restored here.
```

## Gotchas

- `Program::draw` returns geometry in drawing order. Split into layers when you want different caching strategies (static grid + dynamic overlay).
- A `Cache` only invalidates on **size change or explicit `clear()`**. Mutating `Program` fields (e.g. chart data) does **not** invalidate the cache automatically — you must call `cache.clear()` when your data changes.
- Use `frame.fill_rectangle` for rectangles without building a `Path`; the wgpu implementation tessellates a rectangle directly.
- Transformations on the frame use a stack — `with_save` is the push/pop idiom. Forgetting to save/restore leaves transforms in place for subsequent draw calls.
- `into_geometry()` consumes the frame — you cannot add more draw calls after converting.
- Set `.width(Length::Fill)` and `.height(Length::Fill)` or explicit dimensions when the default fixed canvas size does not fit the layout.
- `Program::update` returns `Option<Action<Message>>`. Use `Some(Action::publish(msg))` to emit a message.

## See also

- `canvas-path.md`
- `canvas-geometry.md`
- `shader.md`
- `guide-surface-selection.md`
