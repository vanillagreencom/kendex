# Canvas

> `iced::widget::canvas` · iced 0.14.0

High-level 2D drawing surface. Implement `canvas::Program<Message>` to draw shapes, text, and images via a `Frame`. Use `Cache` to avoid recomputation. Requires the `canvas` feature.

## API

### `Program` trait

```rust
pub trait Program<Message, Theme = Theme, Renderer = Renderer<Renderer, Renderer>>
where
    Renderer: Renderer,
{
    type State: Default + 'static;

    // Required
    fn draw(
        &self,
        state: &Self::State,
        renderer: &Renderer,
        theme: &Theme,
        bounds: Rectangle,
        cursor: Cursor,
    ) -> Vec<<Renderer as Renderer>::Geometry>;

    // Provided
    fn update(
        &self,
        _state: &mut Self::State,
        _event: &Event,
        _bounds: Rectangle,
        _cursor: Cursor,
    ) -> Option<Action<Message>> { ... }

    fn mouse_interaction(
        &self,
        _state: &Self::State,
        _bounds: Rectangle,
        _cursor: Cursor,
    ) -> Interaction { ... }
}
```

- **`State`** — persistent per-widget state (like the rest of iced, this
  lives across frames).
- **`draw(state, renderer, theme, bounds, cursor)`** — produces a `Vec` of
  `Geometry`. You typically create a `Frame`, issue draw calls, then
  `frame.into_geometry()` and collect.
- **`update(state, event, bounds, cursor)`** — process an event,
  optionally mutating state and returning an `Action<Message>` (which can
  publish a message, capture the event, request a redraw, or a combination).
- **`mouse_interaction(state, bounds, cursor)`** — which system cursor to
  display.

### `Frame`

```rust
impl<Renderer> Frame<Renderer> {
    pub fn new(renderer: &Renderer, size: Size) -> Frame<Renderer>;

    // Drawing
    pub fn fill(&mut self, path: &Path, fill: impl Into<Fill>);
    pub fn fill_rectangle(&mut self, top_left: Point, size: Size, fill: impl Into<Fill>);
    pub fn stroke<'a>(&mut self, path: &Path, stroke: impl Into<Stroke<'a>>);
    pub fn fill_text(&mut self, text: impl Into<Text>);

    // Transformations
    pub fn translate(&mut self, translation: Vector);
    pub fn rotate(&mut self, angle: impl Into<Radians>);
    pub fn scale(&mut self, scale: impl Into<f32>);
    pub fn scale_nonuniform(&mut self, scale: impl Into<Vector>);

    // Transform stack
    pub fn with_save<R>(&mut self, f: impl FnOnce(&mut Frame<Renderer>) -> R) -> R;
    pub fn push_transform(&mut self);
    pub fn pop_transform(&mut self);

    pub fn into_geometry(self) -> <Renderer as Renderer>::Geometry;
}
```

- **`new(renderer, size)`** — Creates a frame of the given size. Geometry
  drawn outside the size is clipped.
- **`fill(path, fill)`** — Fills a `Path` with a `Fill` style.
- **`fill_rectangle(top_left, size, fill)`** — Fast path for axis-aligned
  rectangles without building a path.
- **`stroke(path, stroke)`** — Strokes a `Path` with a `Stroke` style.
- **`fill_text(text)`** — Draws text; accepts any `impl Into<Text>`.
- **Transformation methods** — `translate`, `rotate`, `scale`, and
  `scale_nonuniform` modify the current coordinate system.
- **`with_save(f)`** — Runs `f` inside a saved transform stack; on return,
  the transform is popped automatically (RAII form of
  `push_transform`/`pop_transform`).
- **`into_geometry()`** — Consumes the frame and returns its `Geometry`.

### `Cache`

```rust
impl<Renderer> Cache<Renderer> {
    pub fn new() -> Cache<Renderer>;
    pub fn with_group(group: Group) -> Cache<Renderer>;
    pub fn clear(&self);

    pub fn draw(
        &self,
        renderer: &Renderer,
        size: Size,
        draw_fn: impl FnOnce(&mut Frame<Renderer>),
    ) -> <Renderer as Renderer>::Geometry;

    pub fn draw_with_bounds(
        &self,
        renderer: &Renderer,
        bounds: Rectangle,
        draw_fn: impl FnOnce(&mut Frame<Renderer>),
    ) -> <Renderer as Renderer>::Geometry;
}
```

Stores generated `Geometry` to avoid recomputation. Only redraws when dimensions change or `clear()` is called.

## Patterns

### Draw a circle

```rust
use iced::mouse;
use iced::widget::canvas;
use iced::{Color, Rectangle, Renderer, Theme};

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

- `Program::draw` returns `Vec<Geometry>` — each element is a **separate
  layer**. Order matters: later geometries are drawn on top. Split into
  layers when you want different caching strategies (static grid + dynamic
  overlay).
- A `Cache` only invalidates on **size change or explicit `clear()`**.
  Mutating `Program` fields (e.g. chart data) does **not** invalidate the
  cache automatically — you must call `cache.clear()` when your data
  changes.
- `frame.fill_rectangle` is faster than building a `Path::rectangle`
  because it bypasses the path pipeline.
- Transformations on the frame use a stack — `with_save` is the
  push/pop idiom. Forgetting to save/restore leaves transforms in place for
  subsequent draw calls.
- `into_geometry()` consumes the frame — you cannot add more draw calls
  after converting.
- `Canvas` intrinsic size is shrink by default — set `.width(Length::Fill)`
  and `.height(Length::Fill)` (or fixed values) when wrapping in a layout.
- `Program::update` returns `Action<Message>`, not `Option<Message>`. Use `Action::publish(msg)`.

## See also

- `canvas-path.md`
- `canvas-geometry.md`
- `shader.md`
- `guide-surface-selection.md`
