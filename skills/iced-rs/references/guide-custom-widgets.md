# Building Custom Widgets with `iced::advanced`

When you need layout, event handling, hit-testing, persistent state, or overlays that the built-in widgets don't provide, implement `iced::advanced::widget::Widget` directly.

**Read order**: this guide → `advanced-widget.md` → `advanced-tree.md` → `advanced-shell.md` → `advanced-layout.md` → the canonical examples (see below).

## Canonical examples in this skill

- **`examples/custom_widget/src/main.rs`** — Minimal Widget (draws a circle). Start here.
- **`examples/toast/src/main.rs`** — Animated lifetime, auto-dismiss, overlay positioning, `Widget::overlay()`.
- **`examples/loupe/src/main.rs`** — Hit-testing with `cursor.position_over()`, overlay rendering.
- **`examples/modal/src/main.rs`** — Modal via `stack` + `opaque` (no custom overlay).
- **`examples/custom_shader/`** — Custom GPU widget.
- **`examples/geometry/src/main.rs`** — Mesh drawing with `Mesh2D` primitive.

Always read at least `custom_widget` before writing your own — 0.14 signatures changed from 0.13.

## The Widget trait at a glance

```rust
use iced::advanced::layout::{self, Layout};
use iced::advanced::widget::{self, Widget, tree};
use iced::advanced::{mouse, renderer, Clipboard, Shell};
use iced::{Element, Event, Length, Rectangle, Size};

pub struct MyWidget { /* config */ }

impl<Message, Theme, Renderer> Widget<Message, Theme, Renderer> for MyWidget
where
    Renderer: renderer::Renderer,
{
    // === REQUIRED ===
    fn size(&self) -> Size<Length> { /* Fill, Shrink, or Fixed */ }

    fn layout(
        &mut self,
        tree: &mut widget::Tree,
        renderer: &Renderer,
        limits: &layout::Limits,
    ) -> layout::Node { /* return a Node representing this widget's computed geometry */ }

    fn draw(
        &self,
        tree: &widget::Tree,
        renderer: &mut Renderer,
        theme: &Theme,
        style: &renderer::Style,
        layout: Layout<'_>,
        cursor: mouse::Cursor,
        viewport: &Rectangle,
    ) { /* draw primitives via the renderer */ }

    // === PERSISTENT STATE (override if your widget keeps state across frames) ===
    fn tag(&self) -> tree::Tag { tree::Tag::of::<MyState>() }
    fn state(&self) -> tree::State { tree::State::new(MyState::default()) }

    // === COMPOSITE (override if you wrap child widgets) ===
    fn children(&self) -> Vec<widget::Tree> { /* children trees */ }
    fn diff(&self, tree: &mut widget::Tree) { /* reconcile with latest children */ }

    // === EVENTS (override if you care about input) ===
    fn update(
        &mut self,
        tree: &mut widget::Tree,
        event: &Event,                // NOTE: &Event by reference in 0.14
        layout: Layout<'_>,
        cursor: mouse::Cursor,
        renderer: &Renderer,
        clipboard: &mut dyn Clipboard,
        shell: &mut Shell<'_, Message>,
        viewport: &Rectangle,
    ) { /* handle events, publish messages, capture */ }

    fn mouse_interaction(
        &self,
        tree: &widget::Tree,
        layout: Layout<'_>,
        cursor: mouse::Cursor,
        viewport: &Rectangle,
        renderer: &Renderer,
    ) -> mouse::Interaction { mouse::Interaction::None }

    // === OVERLAYS (for popovers, menus, tooltips) ===
    fn overlay<'a>(
        &'a mut self,
        tree: &'a mut widget::Tree,
        layout: Layout<'a>,
        renderer: &Renderer,
        viewport: &Rectangle,
        translation: iced::Vector,
    ) -> Option<iced::advanced::overlay::Element<'a, Message, Theme, Renderer>> {
        None
    }
}

impl<'a, Message, Theme, Renderer> From<MyWidget> for Element<'a, Message, Theme, Renderer>
where
    Renderer: renderer::Renderer,
{
    fn from(widget: MyWidget) -> Self {
        Element::new(widget)
    }
}
```

Full trait reference: `advanced-widget.md`.

## Step-by-step checklist

### 1. Decide if you actually need `iced::advanced::Widget`

Yes if any: persistent per-widget state, custom overlay, custom event capture, non-rectangular hit-testing, custom drawing primitives.

No if: visual styling only → `style` closures. 2D drawing only → `Canvas`. See `guide-surface-selection.md`.

### 2. Design the state

All persistent state lives in `widget::Tree`, **not** the widget struct (recreated every frame from `view()`).

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

**Gotcha:** `tag()` and `state()` must agree. If you return `Tag::of::<MyState>()` but `state()` returns `State::None`, any `downcast_*` call will panic.

### 3. Implement `layout`

`layout` returns a `layout::Node` describing your widget's size. `limits` tells you the available space.

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

`draw` uses the `renderer` to paint quads, text, and custom primitives. The simplest primitive is `renderer::Quad`:

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

In composite custom widgets, the child draw order in your `draw()` implementation determines z-order. The **last child drawn appears on top**. Do not assume `stack` semantics apply automatically inside manual draw loops.

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

If you iterate children in insertion order but need a different visual stacking, reorder the draw calls — not the children themselves (that would break Tree associations). See `guide-animated-layout.md` § "Keyed identity" for reorder-safe patterns.

**Diagnostic**: if background items appear above foreground items, or opacity/layering looks inverted, check the draw iteration order.

#### Opacity and fade completeness

When a component fades as one visual unit (dismiss animation, opacity transition), every rendering path must participate in the opacity:

- Container backgrounds and borders
- Text colors
- Button backgrounds and text
- SVG / image content
- Canvas program output
- Custom shader primitives
- Any embedded child widget content

Partial fade contracts — where some children fade but others don't — produce "nearly transparent remnants." The cause is rendering paths that don't read the current opacity.

**Rule**: audit every rendering path in the component.

#### SVG alpha caveat

SVG tint alpha may not behave identically to text/container/canvas color alpha in all renderers. Before relying on SVG color tint for fade animations:

1. Verify actual rendered alpha at near-zero opacity values
2. Compare SVG fade appearance with text fade at the same alpha
3. If they diverge, use `renderer.with_layer()` with an opacity-controlled clipping region, or render through a composition path that guarantees uniform opacity

Behavior may vary between backends. Verify empirically when fade correctness matters.

### 5. Handle events in `update`

`event: &Event` is passed **by reference** in iced 0.14 (this changed from 0.13 — a common failure mode in generated code).

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

**Capture when you consume.** If your widget handles a click, call `shell.capture_event()` so parent containers don't also react. This is the #1 source of "the drag is also firing a click" bugs.

See `advanced-shell.md` for all Shell methods.

### 6. Animation

Animations need two pieces: (a) stored progress in `Tree` state, (b) a redraw request each frame.

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

**Diagnostic**: if a widget "only updates on the second click," suspect stale layout. Add `invalidate_layout()`.

#### Redraw vs rebuild invariant

`request_redraw()` repaints the existing widget tree — it does **not** call `view()` or rebuild widget structs.

- If animation state lives in widget struct fields (computed in `view()`), redraws repaint **stale values** — the widget struct hasn't changed.
- If animation state lives in `widget::Tree` state, redraws correctly read the updated values from Tree.
- If animation depends on app state recomputation (values set in `App::update()`), it must be driven by messages/tasks that trigger `update()` → `view()`, not bare `request_redraw()`.

**Rule**: redraw-driven animation loops must keep all motion state in `widget::Tree` state. Values computed in `view()` and stored on the widget struct are frozen until the next `view()` call.

For scheduled next-frame ticks:
```rust
shell.request_redraw_at(
    window::RedrawRequest::At(Instant::now() + Duration::from_millis(16))
);
```

### 7. Hit-testing

Use `Cursor::is_over(bounds)` or `Cursor::position_over(bounds)` (returns `Option<Point>`):

```rust
if let Some(local) = cursor.position_over(layout.bounds()) {
    // local.x and local.y are relative to widget origin
}
```

For non-rectangular hit-testing (circles, paths), compute manually against bounds.

### Stable hover hit regions

Hover sensors must not be attached to layout-affecting animated bounds. If a `mouse_area` wraps content whose size changes during a hover-triggered animation, the sensor boundary moves during animation, causing enter/exit thrashing:

1. Content starts small → cursor enters → animation grows content
2. Sensor boundary moves → cursor is now outside → exit fires
3. Content shrinks → cursor is inside again → enter fires
4. Result: visible flickering

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

Parents like `scrollable` listen for mouse events and can steal drags. If your widget starts a drag, **capture the event**:

```rust
Event::Mouse(mouse::Event::ButtonPressed(_)) if cursor.is_over(bounds) => {
    state.drag_origin = cursor.position();
    shell.capture_event();  // <-- critical
}
```

Without `capture_event()`, the parent `scrollable` will also process the mouse-down and start scrolling.

### 9. Construction API

Provide a free-function constructor for ergonomic use in `view()`:

```rust
pub fn my_widget(value: f32) -> MyWidget {
    MyWidget { value, width: Length::Fill, height: Length::Fixed(40.0) }
}

impl MyWidget {
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
    From<MyWidget> for Element<'a, Message, Theme, Renderer>
{
    fn from(w: MyWidget) -> Self { Element::new(w) }
}
```

Used in `view()` as `my_widget(self.value).width(300).on_press(Message::Tick).into()`.

## Common failure modes

| Symptom | Cause | Fix |
|--|--|--|
| `downcast_mut` panics | `tag()` and `state()` disagree | Make sure both use the same concrete type |
| Widget doesn't update on click | Event not captured; parent swallowed it | `shell.capture_event()` after handling |
| Animation stutters or stops | Missing redraw request | `shell.request_redraw()` every animating frame |
| Animation paints at wrong size | Layout-affecting animation without `invalidate_layout()` | Add `shell.invalidate_layout()` |
| "Second click only" bug | Stale layout from previous state flip | `shell.invalidate_layout()` when geometry changes |
| Drag conflicts with scroll | Missing `capture_event()` during drag | Capture while dragging |
| Compile error `expected Event, found &Event` | Used 0.13 signature | `update` takes `event: &Event` in 0.14 |
| Compile error in `layout()` signature | Used 0.13 signature | Takes `&mut Tree` in 0.14 |
| Trait bound `Renderer` unsatisfied | Missing `renderer::Renderer` constraint | Add `where Renderer: renderer::Renderer` |
| Widget state reset unexpectedly | Changed the `T` in `Tag::of::<T>()` | Keep the state type stable across frames |
| Layering looks inverted | Wrong draw order in composite widget | Last drawn = on top; reorder draw calls |
| Hover flickers during animation | Hover sensor on animated bounds | Use stable outer hitbox; see § "Stable hover hit regions" |
| Near-transparent remnants after fade | Partial fade contract | Audit all rendering paths for opacity; see § "Opacity and fade" |
| SVG doesn't fade with rest of component | SVG tint alpha diverges from container alpha | Verify renderer behavior; use `with_layer` if needed |
| Animation frozen / doesn't advance | Motion state in widget fields, not Tree | Move to `tree.state`; see § "Redraw vs rebuild invariant" |

## Constraints from the wider framework

Non-negotiable — violating causes subtle bugs:

- **Widget tree consistency** — always wrap, conditionally attach the handler. Never `if cond { mouse_area(x).into() } else { x.into() }`. `MouseArea` has **no `on_press_maybe`** (that is `button`-only); its `on_press` takes a plain `Message`, so keep the wrapper unconditional and gate the call: `let mut a = mouse_area(x); if cond { a = a.on_press(msg); } a`.
- **`view()` is pure** — no side effects, no mutable state. All state in `State`, mutated only in `update()`.
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
