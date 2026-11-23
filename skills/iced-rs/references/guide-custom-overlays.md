# Building Custom Overlays

Read when implementing a floating layer that the built-in widgets cannot express. An overlay has its own layout pass above the normal widget tree.

**Read order**: this guide → `advanced-overlay.md` → `advanced-widget.md` (for the `overlay()` method on `Widget`).

## Built-ins

Check the built-ins before implementing `Overlay`:

| You want | Use |
|---|---|
| A simple tooltip | `iced::widget::tooltip` |
| A choice list anchored to a trigger | `iced::widget::pick_list` or `combo_box` |
| A popover under a trigger | `float` after the trigger (`widget-float.md` § Anchoring to a trigger), or the template the list below names |
| A modal dialog with scrim | `stack![base, opaque(scrim_and_dialog)]` |
| Drag ghost during DnD | `pin` widget + absolute positioning |
| Context menu | `mouse_area` that opens a `float` or `stack` layer |

Use the [copy-paste overlay template](#copy-paste-overlay-template) instead of `float` for a popover under a trigger when any of these holds:

- The open popover must cover the content after the trigger without moving it. A float keeps its layout footprint.
- The popover must flip above the trigger, or otherwise place itself from the trigger's size. Float's `translate` never receives the trigger's bounds; the template's `overlay()` computes them as `layout.bounds() + translation`.
- The popover must extend past an enclosing `scrollable`. Float clips its floating layer to the scrollable's visible bounds; the template lays out against the window.

For a popover under the trigger, swap the template's vertical order in `Overlay::layout()`: below preferred, above as the fallback.

Use the [modal example](../examples/modal/src/main.rs) for the full scrim and dialog nesting.

### Modal nesting order (exact — do not rearrange)

Copy this exactly:

```
stack![
    base_content,                              // layer 0: the app behind the modal
    opaque(                                    // layer 1: outer opaque captures in-bounds mouse presses
        mouse_area(                            //   scrim click target
            center(                            //   center the dialog
                opaque(                        //   INNER opaque — stops dialog clicks
                    container(dialog_content)  //     from reaching the scrim's mouse_area
                )
            )
        )
        .on_press(Message::CloseModal)         //   scrim click → close
    )
]
```

**Common mistakes:**

- Missing outer `opaque` → base content receives clicks through the scrim
- Missing inner `opaque` → clicking inside the dialog dismisses it
- Keep the opaque scrim in the open modal layer. The outer wrapper captures in-bounds mouse presses after forwarding to its content.
- Keep the scrim’s `mouse_area` inside the outer `opaque`. The outer wrapper would otherwise capture the press before the scrim handler receives it.

**All close paths must call the same handler.** Extract one helper:

```rust
fn close_modal(&mut self) {
    self.modal_phase.begin_close();  // or: self.show_modal = false;
}

// Wire from every close source:
Message::ScrimClicked => self.close_modal(),
Message::CancelPressed => self.close_modal(),
Message::SubmitPressed => { self.save(); self.close_modal(); }
Message::EscapePressed => self.close_modal(),
```

If none of those fit (viewport-aware positioning, non-rectangular shapes, complex animation), keep reading.

## Overlay API

See the [`Overlay` trait and `from_children`](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/overlay.rs) and [advanced-overlay.md](advanced-overlay.md). `layout()` takes a `Size`. The overlay has no `size()` method, and its `draw()` and `update()` methods have no viewport parameter.

## The custom overlay contract — MUST follow

Pair each forwarded child with its own Tree entry and the layout produced for that child. A missing child layout can panic when a composite widget expects one.

### 1. `children()` returns a **fixed count**

The child tree count must not depend on overlay visibility.

```rust
// WRONG
fn children(&self) -> Vec<Tree> {
    if self.overlay_open {
        vec![Tree::new(&self.anchor), Tree::new(&self.popup)]
    } else {
        vec![Tree::new(&self.anchor)]
    }
}

// RIGHT
fn children(&self) -> Vec<Tree> {
    vec![Tree::new(&self.anchor), Tree::new(&self.popup)]  // always both
}
```

### 2. `diff()` reconciles **all children** regardless of visibility

Do not skip `diff()` for hidden children.

```rust
// WRONG
fn diff(&self, tree: &mut Tree) {
    tree.children[0].diff(&self.anchor);
    if self.overlay_open {
        tree.children[1].diff(&self.popup);  // skipped when closed!
    }
}

// RIGHT
fn diff(&self, tree: &mut Tree) {
    tree.children[0].diff(&self.anchor);
    tree.children[1].diff(&self.popup);  // always
}
```

### 3. Lay out the child each pass forwards

Lay out the anchor in the base pass. Lay out the popup in the overlay pass.

### 4. Forward the corresponding Tree entry and layout

Use each child’s own state and layout when forwarding `draw()` or other widget methods.

### 5. Invalidate layout when overlay visibility changes

When `Widget::overlay()` transitions between `Some` and `None`, call `shell.invalidate_layout()` where you flip the flag:

```rust
Event::Mouse(mouse::Event::CursorEntered) => {
    if !state.show_overlay {
        state.show_overlay = true;
        shell.invalidate_layout();  // refresh layout and overlay placement
    }
}
```

## Overlay viewport

In this pattern, pass `Rectangle::INFINITE` as the viewport to descendant `Widget` calls from the overlay. An inherited parent viewport can clip overlay content outside the parent’s bounds.

Exception: `Overlay::layout()` may use `bounds: Size` for its own coordinate space.

### Example

```rust
impl<'a, Message, Theme, Renderer> iced::advanced::overlay::Overlay<Message, Theme, Renderer>
    for MyOverlay<'a, Message, Theme, Renderer>
{
    fn update(
        &mut self,
        event: &Event,
        layout: Layout<'_>,
        cursor: Cursor,
        renderer: &Renderer,
        clipboard: &mut dyn Clipboard,
        shell: &mut Shell<'_, Message>,
    ) {
        // forwarding to a descendant widget
        self.content.as_widget_mut().update(
            self.tree,
            event,
            layout,
            cursor,
            renderer,
            clipboard,
            shell,
            &Rectangle::INFINITE,
        );
    }
}
```

## Positioning patterns

### Above-anchor preferred, fallback to below

```rust
fn layout(&mut self, _renderer: &Renderer, bounds: Size) -> Node {
    let popup_size = Size::new(self.content_width, self.content_height);

    // Preferred: above
    let above_y = self.anchor_bounds.y - popup_size.height - SPACING;
    let below_y = self.anchor_bounds.y + self.anchor_bounds.height + SPACING;

    let y = if above_y >= 0.0 {
        above_y.min((bounds.height - popup_size.height).max(0.0))
    } else if below_y + popup_size.height <= bounds.height {
        below_y
    } else {
        // Neither fits — clamp to viewport top
        0.0
    };

    // Horizontal: clamp to viewport edges
    let x = (self.anchor_bounds.x + self.anchor_bounds.width * 0.5 - popup_size.width * 0.5)
        .max(0.0)
        .min((bounds.width - popup_size.width).max(0.0));

    Node::new(popup_size).move_to(Point::new(x, y))
}
```

### Follow through scrollables

`translation` in `Widget::overlay()` is the accumulated parent translation (from scrollables). Offset the laid-out anchor by it:

```rust
fn overlay<'a>(
    &'a mut self,
    tree: &'a mut Tree,
    layout: Layout<'a>,
    _renderer: &Renderer,
    _viewport: &Rectangle,
    translation: Vector,
) -> Option<overlay::Element<'a, Message, Theme, Renderer>> {
    let anchor_bounds = layout.bounds() + translation;  // <-- offset by translation
    Some(overlay::Element::new(Box::new(MyOverlay { anchor_bounds, /* ... */ })))
}
```

Without this, overlays do not follow the anchor as it scrolls.

## Sibling overlays and z-index

`Overlay::index(&self) -> f32` — z-index for ordering overlays. Higher = on top. Default `1.0`.

## Composite widgets forwarding overlays

Forward child overlays with `overlay::from_children()`:

```rust
fn overlay<'a>(
    &'a mut self,
    tree: &'a mut Tree,
    layout: Layout<'a>,
    renderer: &Renderer,
    viewport: &Rectangle,
    translation: Vector,
) -> Option<overlay::Element<'a, Message, Theme, Renderer>> {
    overlay::from_children(
        &mut self.children,
        tree,
        layout,
        renderer,
        viewport,
        translation,
    )
}
```

If a child tooltip or popover does not appear, check that the composite forwards the child’s overlay.

## Copy-paste overlay template

Copy this template and keep the two-child tree shape.

```rust
use iced::advanced::layout::{Layout, Limits, Node};
use iced::advanced::overlay;
use iced::advanced::renderer;
use iced::advanced::widget::{self, Widget};
use iced::advanced::{Clipboard, Shell};
use iced::{Element, Event, Length, Point, Rectangle, Size, Vector, mouse};

/// Wrapper widget that shows `content` as an overlay above `anchor` when `show` is true.
pub struct WithOverlay<'a, Message, Theme, Renderer> {
    anchor: Element<'a, Message, Theme, Renderer>,
    content: Element<'a, Message, Theme, Renderer>,
    show: bool,
}

impl<'a, Message, Theme, Renderer> Widget<Message, Theme, Renderer>
    for WithOverlay<'a, Message, Theme, Renderer>
where
    Renderer: renderer::Renderer,
{
    // ALWAYS two children regardless of `show`
    fn children(&self) -> Vec<widget::Tree> {
        vec![
            widget::Tree::new(&self.anchor),
            widget::Tree::new(&self.content),
        ]
    }

    // ALWAYS diff both children regardless of `show`
    fn diff(&self, tree: &mut widget::Tree) {
        tree.diff_children(&[&self.anchor, &self.content]);
    }

    fn size(&self) -> Size<Length> { self.anchor.as_widget().size() }

    fn layout(&mut self, tree: &mut widget::Tree, renderer: &Renderer,
              limits: &Limits) -> Node {
        // Layout ONLY the anchor here; content is laid out in the overlay pass
        self.anchor.as_widget_mut().layout(
            &mut tree.children[0], renderer, limits,
        )
    }

    fn draw(&self, tree: &widget::Tree, renderer: &mut Renderer, theme: &Theme,
            style: &renderer::Style, layout: Layout<'_>, cursor: mouse::Cursor,
            viewport: &Rectangle) {
        self.anchor.as_widget().draw(
            &tree.children[0], renderer, theme, style, layout, cursor, viewport,
        );
    }

    fn update(&mut self, tree: &mut widget::Tree, event: &Event,
              layout: Layout<'_>, cursor: mouse::Cursor, renderer: &Renderer,
              clipboard: &mut dyn Clipboard, shell: &mut Shell<'_, Message>,
              viewport: &Rectangle) {
        self.anchor.as_widget_mut().update(
            &mut tree.children[0], event, layout, cursor,
            renderer, clipboard, shell, viewport,
        );
    }

    fn mouse_interaction(&self, tree: &widget::Tree, layout: Layout<'_>,
                         cursor: mouse::Cursor, viewport: &Rectangle,
                         renderer: &Renderer) -> mouse::Interaction {
        self.anchor.as_widget().mouse_interaction(
            &tree.children[0], layout, cursor, viewport, renderer,
        )
    }

    fn overlay<'b>(&'b mut self, tree: &'b mut widget::Tree,
                   layout: Layout<'b>, _renderer: &Renderer,
                   _viewport: &Rectangle, translation: Vector,
    ) -> Option<overlay::Element<'b, Message, Theme, Renderer>> {
        if !self.show { return None; }

        let anchor = layout.bounds() + translation;

        Some(overlay::Element::new(Box::new(ContentOverlay {
            content: &mut self.content,
            tree: &mut tree.children[1],
            anchor,
        })))
    }
}

// ── Overlay impl ─────────────────────────────────────────────────────
struct ContentOverlay<'a, 'b, Message, Theme, Renderer> {
    content: &'b mut Element<'a, Message, Theme, Renderer>,
    tree: &'b mut widget::Tree,
    anchor: Rectangle,
}

impl<'a, 'b, Message, Theme, Renderer>
    overlay::Overlay<Message, Theme, Renderer>
    for ContentOverlay<'a, 'b, Message, Theme, Renderer>
where
    Renderer: renderer::Renderer,
{
    fn layout(&mut self, renderer: &Renderer, bounds: Size) -> Node {
        let limits = Limits::new(Size::ZERO, bounds);
        let node = self.content.as_widget_mut().layout(
            self.tree, renderer, &limits,
        );

        // Position: above anchor preferred, below fallback, clamp horizontal
        let popup_h = node.size().height;
        let above_y = self.anchor.y - popup_h - 4.0;
        let below_y = self.anchor.y + self.anchor.height + 4.0;
        let y = if above_y >= 0.0 {
            above_y.min((bounds.height - popup_h).max(0.0))
        } else if below_y + popup_h <= bounds.height {
            below_y
        } else {
            0.0
        };
        let x = (self.anchor.center_x() - node.size().width * 0.5)
            .max(0.0)
            .min((bounds.width - node.size().width).max(0.0));

        node.move_to(Point::new(x, y))
    }

    fn draw(&self, renderer: &mut Renderer, theme: &Theme,
            style: &renderer::Style, layout: Layout<'_>,
            cursor: mouse::Cursor) {
        self.content.as_widget().draw(
            self.tree, renderer, theme, style, layout, cursor,
            &Rectangle::INFINITE,  // ← CRITICAL: never forward parent viewport
        );
    }

    fn update(&mut self, event: &Event, layout: Layout<'_>,
              cursor: mouse::Cursor, renderer: &Renderer,
              clipboard: &mut dyn Clipboard,
              shell: &mut Shell<'_, Message>) {
        self.content.as_widget_mut().update(
            self.tree, event, layout, cursor, renderer, clipboard, shell,
            &Rectangle::INFINITE,  // ← CRITICAL
        );
    }

    fn mouse_interaction(&self, layout: Layout<'_>, cursor: mouse::Cursor,
                         renderer: &Renderer) -> mouse::Interaction {
        self.content.as_widget().mouse_interaction(
            self.tree, layout, cursor, &Rectangle::INFINITE, renderer,
        )
    }
}
```

**Rigid (the overlay contract — never change):**

- `children()` returns exactly 2, always, regardless of `show`
- `diff()` reconciles both children when the runtime rebuilds the widget tree
- `overlay()` switches on `show` → `Some`/`None`, never changes child count
- Overlay descendant calls that take a viewport pass `&Rectangle::INFINITE`

**Customizable:**

- **Positioning** — replace `Overlay::layout()` math
- **Content** — `self.content` is any `Element` tree
- **Trigger** — hover, click, right-click, focus, keyboard shortcut, state flag
- **Animation** — fade/scale/slide via `Widget::update()` on `RedrawRequested`
- **Multiple overlays** — `overlay::Group::with_children(vec![...]).overlay()`
- **Z-index** — `Overlay::index()` (default 1.0)

The anchor and popup keep their Tree entries through visibility changes.

## Testing your overlay

- Hover → show → hover away → hide → verify no panic
- Open overlay while inside a `scrollable`, then scroll → verify it follows (or hides if out of view)
- Open overlay, resize the window → verify positioning adjusts
- Open two overlays from the same root → verify z-index ordering
- Open overlay with content wider/taller than viewport → verify clamping

## Still unsure?

Default to `stack![base, opaque(modal)]` or the built-in `tooltip`/`float`/`pick_list` widgets.

## See also

- `advanced-overlay.md`
- `advanced-widget.md`
- `widget-tooltip.md`
- `widget-float.md`
- `widget-stack.md`
