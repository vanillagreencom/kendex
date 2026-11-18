# Building Custom Widgets with `iced::advanced`

Read when implementing `iced::advanced::Widget` for layout, events, hit-testing, persistent state, or overlays that the built-in widgets cannot express.

**Read order**: this guide → `advanced-widget.md` → `advanced-tree.md` → `advanced-shell.md` → `advanced-layout.md` → the canonical examples (see below).

## Canonical examples in this skill

- **`examples/custom_widget/src/main.rs`** — Minimal Widget (draws a circle). Start here.
- [Toast](../examples/toast/src/main.rs) positions notifications and dismisses them after a timeout from a composite widget overlay.
- [Loupe](../examples/loupe/src/main.rs) clips and transforms drawing around the cursor.
- **`examples/modal/src/main.rs`** — Modal via `stack` + `opaque` (no custom overlay).
- **`examples/custom_shader/`** — Custom GPU widget.
- **`examples/geometry/src/main.rs`** — Mesh drawing with `Mesh2D` primitive.

Always read at least `custom_widget` before writing your own.

## Widget API

See the [`Widget` trait](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/widget.rs) for the required `size`, `layout`, and `draw` methods and optional callbacks. Use [advanced-widget.md](advanced-widget.md) to choose which callbacks to implement.

## Step-by-step checklist

### 1. Decide if you actually need `iced::advanced::Widget`

Yes if any: persistent per-widget state, custom overlay, custom event capture, non-rectangular hit-testing, custom drawing primitives.

No if: visual styling only → `style` closures. 2D drawing only → `Canvas`. See `guide-surface-selection.md`.

### 2. Design the state

Keep persistent per-widget interaction and motion state in `widget::Tree`. Use fields on the widget for configuration passed from the view.

```rust
#[derive(Default)]
struct MyState {
    hovered: bool,
    animation: Option<f32>,
    drag_origin: Option<Point>,
}

fn tag(&self) -> tree::Tag { tree::Tag::of::<MyState>() }
fn state(&self) -> tree::State { tree::State::new(MyState::default()) }
```

Access state in callbacks:

```rust
let state = tree.state.downcast_mut::<MyState>();
state.hovered = cursor.is_over(layout.bounds());
```

**Gotcha:** `tag()` and `state()` must use the same concrete type, or `downcast_*` panics.

### 3. Implement `layout`

`layout` returns a `layout::Node` for your widget's size; `limits` is the available space.

```rust
fn layout(
    &mut self,
    _tree: &mut widget::Tree,
    _renderer: &Renderer,
    limits: &layout::Limits,
) -> layout::Node {
    let size = limits.resolve(self.width, self.height, Size::new(100.0, 100.0));
    layout::Node::new(size)
}
```

For composite widgets wrapping children, use `layout::Node::with_children`. See `advanced-layout.md`.

### 4. Implement `draw`

`draw` paints quads, text, and custom primitives via `renderer`. Simplest primitive: `renderer::Quad`:

```rust
fn draw(
    &self,
    _tree: &widget::Tree,
    renderer: &mut Renderer,
    _theme: &Theme,
    _style: &renderer::Style,
    layout: Layout<'_>,
    _cursor: mouse::Cursor,
    _viewport: &Rectangle,
) {
    renderer.fill_quad(
        renderer::Quad {
            bounds: layout.bounds(),
            border: iced::border::rounded(4),
            ..Default::default()
        },
        iced::Color::from_rgb(0.2, 0.5, 0.8),
    );
}
```

Drawing text requires `Renderer: iced::advanced::text::Renderer`. See `advanced-text.md` and `advanced-renderer.md`.

#### Draw order is z-order

In composite widgets, child draw order in `draw()` is z-order: **last drawn is on top**. `stack` semantics do not apply inside manual draw loops.

```rust
fn draw(&self, tree: &Tree, renderer: &mut Renderer, /* ... */) {
    // Background drawn first — appears behind everything
    self.background.draw(&tree.children[0], renderer, /* ... */);

    // Main content — appears above background
    self.content.draw(&tree.children[1], renderer, /* ... */);

    // Overlay decoration — drawn last, appears on top
    self.decoration.draw(&tree.children[2], renderer, /* ... */);
}
```

For a different visual stacking, reorder the draw calls — never the children (breaks Tree associations). See `guide-animated-layout.md` § "Keyed identity" for reorder-safe patterns.

**Diagnostic**: inverted layering → check draw iteration order.

#### Opacity and fade completeness

When a component fades as one unit, every rendering path must apply the opacity:

- Container backgrounds and borders
- Text colors
- Button backgrounds and text
- SVG / image content
- Canvas program output
- Custom shader primitives
- Any embedded child widget content

**Rule**: audit every rendering path in the component; any path that ignores opacity leaves "nearly transparent remnants."

#### SVG alpha caveat

SVG tint alpha may diverge from text/container/canvas alpha. Before relying on SVG tint for fades:

1. Verify actual rendered alpha at near-zero opacity values
2. Compare SVG fade appearance with text fade at the same alpha
3. If they diverge, pass the fade value through `Svg::opacity` or use a composition path that applies opacity to every child. `renderer.with_layer()` clips drawing.

### 5. Handle events in `update`

`event: &Event` is passed **by reference** in iced 0.14.

```rust
fn update(
    &mut self,
    tree: &mut widget::Tree,
    event: &Event,
    layout: Layout<'_>,
    cursor: mouse::Cursor,
    _renderer: &Renderer,
    _clipboard: &mut dyn Clipboard,
    shell: &mut Shell<'_, Message>,
    _viewport: &Rectangle,
) {
    let state = tree.state.downcast_mut::<MyState>();
    let bounds = layout.bounds();

    match event {
        Event::Mouse(mouse::Event::CursorMoved { .. }) => {
            let now_hovered = cursor.is_over(bounds);
            if now_hovered != state.hovered {
                state.hovered = now_hovered;
                shell.request_redraw();
            }
        }
        Event::Mouse(mouse::Event::ButtonPressed(mouse::Button::Left)) => {
            if cursor.is_over(bounds) {
                shell.publish((self.on_press)());
                shell.capture_event();  // prevent bubble
            }
        }
        _ => {}
    }
}
```

Call `shell.capture_event()` when the widget consumes an event. A parent that checks capture status can then stop routing that event.

See `advanced-shell.md` for all Shell methods.

### 6. Animation

Keep widget-driven progress in Tree state and request another redraw while motion is active.

**Paint-only animation** (color, opacity, transform, fixed bounds):

```rust
if state.animation_active {
    shell.request_redraw();  // that's it
}
```

**Layout-affecting animation** (size, position, expand/collapse, clipping bounds):

```rust
if state.animation_active {
    shell.invalidate_layout();  // REQUIRED — otherwise paint at new size with old layout
    shell.request_redraw();
}
```

If geometry updates on a second click, check whether the first interaction invalidated layout.

#### Redraw vs rebuild invariant

A redraw request on its own repaints the existing tree. Published messages and widget invalidation can cause a rebuild.

**Rule**: redraw-driven animation loops keep all motion state in `widget::Tree` state; widget struct fields are frozen until the next `view()`. Animation that depends on `App::update()` values must be driven by messages/tasks, not bare `request_redraw()`.

For scheduled next-frame ticks:

```rust
shell.request_redraw_at(Instant::now() + Duration::from_millis(16));
```

### 7. Hit-testing

Use `Cursor::is_over(bounds)` to test containment. Use `position_in(bounds)` for local coordinates and `position_over(bounds)` to keep the original coordinates:

```rust
if let Some(local) = cursor.position_in(layout.bounds()) {
    // local.x and local.y are relative to widget origin
}
```

For non-rectangular hit-testing (circles, paths), compute manually against bounds.

### Stable hover hit regions

Hover sensors must not be attached to layout-affecting animated bounds: a `mouse_area` wrapping content that resizes during its own hover animation thrashes enter/exit and flickers.

**Rule**: use a stable outer hitbox. Animated content lives inside the hitbox — it does not define it.

```rust
// BAD: hover sensor wraps animated content — boundary changes during animation
mouse_area(animated_expanding_content)
    .on_enter(Message::Expand)
    .on_exit(Message::Collapse)

// GOOD: stable outer container; animated content inside
mouse_area(
    container(animated_expanding_content)
        .width(FIXED_WIDTH)
        .height(STABLE_HOVER_HEIGHT)  // does not change during animation
)
    .on_enter(Message::Expand)
    .on_exit(Message::Collapse)
```

See `guide-animated-layout.md` for full collapsed-to-expanded transition patterns.

### 8. Scrollable compatibility

If your widget starts a drag, **capture the event** or parents like `scrollable` steal it:

```rust
Event::Mouse(mouse::Event::ButtonPressed(_)) if cursor.is_over(bounds) => {
    state.drag_origin = cursor.position();
    shell.capture_event();  // <-- critical
}
```

### 9. Construction API

For a custom widget with a message type, provide a free-function constructor and fluent setters:

```rust
pub fn my_widget<Message>(value: f32) -> MyWidget<Message> {
    MyWidget {
        value,
        width: Length::Fill,
        height: Length::Fixed(40.0),
        on_press: None,
    }
}

impl<Message> MyWidget<Message> {
    pub fn width(mut self, width: impl Into<Length>) -> Self {
        self.width = width.into();
        self
    }
    pub fn height(mut self, height: impl Into<Length>) -> Self {
        self.height = height.into();
        self
    }
    pub fn on_press(mut self, message: Message) -> Self {
        self.on_press = Some(message);
        self
    }
}

impl<'a, Message: 'a, Theme: 'a, Renderer: 'a + renderer::Renderer>
    From<MyWidget<Message>> for Element<'a, Message, Theme, Renderer>
where
    MyWidget<Message>: Widget<Message, Theme, Renderer>,
{
    fn from(w: MyWidget<Message>) -> Self { Element::new(w) }
}
```

Used in `view()` as `my_widget(self.value).width(300).on_press(Message::Tick).into()`.

## Common failure modes

| Symptom | Cause | Fix |
|--|--|--|
| `downcast_mut` panics | `tag()` and `state()` disagree | Make sure both use the same concrete type |
| Click also reaches a parent handler | Widget consumed the click without setting capture status | Call `shell.capture_event()` after handling |
| Animation stutters or stops | Missing redraw request | `shell.request_redraw()` every animating frame |
| Animation paints at wrong size | Layout-affecting animation without `invalidate_layout()` | Add `shell.invalidate_layout()` |
| "Second click only" bug | Stale layout from previous state flip | `shell.invalidate_layout()` when geometry changes |
| Drag conflicts with scroll | Missing `capture_event()` during drag | Capture while dragging |
| Compile error `expected Event, found &Event` | Used 0.13 signature | `update` takes `event: &Event` in 0.14 |
| Compile error in `layout()` signature | The receiver or Tree argument does not match the trait | Use `&mut self` and `&mut Tree` |
| Trait bound `Renderer` unsatisfied | Missing `renderer::Renderer` constraint | Add `where Renderer: renderer::Renderer` |
| Widget state reset unexpectedly | Changed the `T` in `Tag::of::<T>()` | Keep the state type stable across frames |
| Layering looks inverted | Wrong draw order in composite widget | Last drawn = on top; reorder draw calls |
| Hover flickers during animation | Hover sensor on animated bounds | Use stable outer hitbox; see § "Stable hover hit regions" |
| Near-transparent remnants after fade | Partial fade contract | Audit all rendering paths for opacity; see § "Opacity and fade" |
| SVG does not fade with the rest of the component | Tint and opacity follow separate paths | Check SVG opacity at the fade value |
| Animation frozen / doesn't advance | Motion state in widget fields, not Tree | Move to `tree.state`; see § "Redraw vs rebuild invariant" |

## Constraints from the wider framework

Non-negotiable:

- **Widget tree consistency** — always wrap, conditionally attach the handler. Never `if cond { mouse_area(x).into() } else { x.into() }`. `MouseArea` has **no `on_press_maybe`** (`button`-only); keep the wrapper unconditional and gate the call: `let mut a = mouse_area(x); if cond { a = a.on_press(msg); } a`.
- Keep `view()` free of side effects. Change application state in `update()` and keep persistent widget interaction state in Tree.
- **Single message per interaction** — one interaction → one message. Composite actions use a state machine in `update()`.
- **Overlay state isolation** — overlay layers must not affect base layer widget structure.

## See also

- `advanced-widget.md`
- `advanced-tree.md`
- `advanced-shell.md`
- `advanced-layout.md`
- `guide-custom-overlays.md`
- `guide-animated-layout.md` — measured positions, collapsed/expanded transitions, keyed identity, anti-patterns
- `guide-animation-debugging.md` — symptom→cause checklist for animation/render bugs
- `animation.md` — animation rules, redraw vs rebuild, `Animation<T>`, scheduling
