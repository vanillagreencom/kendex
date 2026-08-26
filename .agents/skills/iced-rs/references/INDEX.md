# References Index

Iced 0.14 API references and guides. Load on demand.

- `api-module-tree.md` — hierarchical index of every public module, trait, struct, enum, function

## Synthesized guides

| File | When to read |
|---|---|
| `guide-surface-selection.md` | Built-in / Canvas / Shader / Widget / Overlay decision tree |
| `guide-custom-widgets.md` | `iced::advanced::Widget` — checklist, state, events, animation, hit-testing |
| `guide-custom-overlays.md` | `iced::advanced::overlay::Overlay` — contract, viewport rule, panic sources |
| `animation.md` | Paint-only vs layout-affecting, redraw scheduling, `Animation<T>`, hand-rolled, easing |
| `animation-easing.md` | `Animation<T>` API (all methods) + `Easing` enum (32 variants) |
| `guide-animated-layout.md` | Animated transitions: measured positions, collapsed/expanded, keyed identity, clipping |
| `guide-animation-debugging.md` | Animation/render bug checklist, symptom→cause table |
| `shell-chrome.md` | Shell UI: action builders, floating menus, tab bars |
| `widgets.md` | Widget catalog: every 0.14 widget, notes, canonical example |

## `iced::advanced` API

| File | Covers |
|---|---|
| `advanced-widget.md` | `Widget` trait — all methods, signatures |
| `advanced-overlay.md` | `Overlay` trait, `Widget::overlay()` contract |
| `advanced-shell.md` | `Shell` — publish, capture_event, request_redraw, invalidate_layout |
| `advanced-tree.md` | `Tree`, `Tag`, `State` — persistent widget state |
| `advanced-layout.md` | `layout::Node`, `Limits`, `Layout` |
| `advanced-renderer.md` | `Renderer` trait, `Quad`, `Style`, `with_layer`, `with_translation` |
| `advanced-mouse.md` | `Cursor`, `Interaction`, `mouse::Event` |
| `advanced-text.md` | `text::Renderer`, `Paragraph`, `Shaping` |
| `advanced-text-editor.md` | `text::editor::Editor` trait, `Action`, `Edit`, `Motion`, `Direction`, `Cursor` |
| `advanced-text-highlighter.md` | `text::highlighter::Highlighter` trait, `Format`, `PlainText` |
| `advanced-subscription-recipe.md` | `subscription::Recipe` trait — custom subscription backends |
| `advanced-clipboard.md` | `Clipboard` trait |
| `advanced-operation.md` | `Operation` trait — focus, scroll-to, introspection |

## `iced::widget` API

| File | Covers |
|---|---|
| `canvas.md` | `Canvas`, `Program`, `Frame`, `Fill`, `Stroke`, `Cache`, `Geometry` |
| `canvas-path.md` | `Path`, `Path::Builder` |
| `canvas-geometry.md` | `Geometry`, cache invalidation |
| `shader.md` | `Shader`, `Program`, `Primitive`, `Pipeline`, `Storage`, `Viewport` |
| `pane-grid.md` | Full pane_grid module |
| `widget-table.md` | `Table`, `Column`, `Catalog`, `Style` — data grids |
| `widget-stack.md` | `Stack` — layered children, push, push_under |
| `widget-float.md` | `Float` — floating overlay with scale/translate |
| `widget-pin.md` | `Pin` — absolute positioning at fixed coordinates |
| `widget-markdown.md` | `markdown::view`, `Item`, `Settings`, `Style` — render Markdown |
| `widget-qr-code.md` | `QRCode`, `Data`, `ErrorCorrection`, `Style` |
| `widget-image.md` | `Image`, `Handle`, `FilterMethod`, content_fit, rotation, crop |
| `widget-svg.md` | `Svg`, `Handle`, `Style`, `Status` — vector graphics |
| `widget-themer.md` | `Themer` — apply a different theme to a subtree |
| `widget-lazy-keyed.md` | `Lazy` + `keyed::Column` |
| `widget-sensor.md` | `Sensor` — on_show, on_resize, on_hide |
| `widget-responsive.md` | `Responsive` — size-aware building |
| `widget-text.md` | `Text`, `Rich`, `Span`, `Shaping`, `Wrapping`, `LineHeight` |
| `widget-column-row.md` | `Column`, `Row`, `column![]`, `row![]` |
| `widget-layout-primitives.md` | `center`, `space`, `horizontal_rule`, `vertical_rule` |
| `widget-mouse-area.md` | `MouseArea` — mouse event interception |
| `widget-button.md` | `Button`, `Catalog`, `Status`, `Style`, `StyleFn` |
| `widget-checkbox.md` | `Checkbox`, `Catalog`, `Style`, `Status`, `Icon` |
| `widget-combo-box.md` | `ComboBox`, `Catalog`, `State` |
| `widget-container.md` | `Container`, `Catalog`, `Style`, `StyleFn` |
| `widget-pick-list.md` | `PickList`, `Catalog`, `Style`, `Handle`, `Status` |
| `widget-progress-bar.md` | `ProgressBar`, `Catalog`, `Style`, `StyleFn` |
| `widget-radio.md` | `Radio`, `Catalog`, `Style`, `Status` |
| `widget-scrollable.md` | `Scrollable`, `Catalog`, `Style`, `Direction`, `Viewport`, `Anchor` |
| `widget-slider.md` | `Slider`, `Catalog`, `Style`, `Handle`, `Status` |
| `widget-text-editor.md` | `TextEditor`, `Catalog`, `Style`, `Status`, `Content`, `Action` |
| `widget-text-input.md` | `TextInput`, `Catalog`, `Style`, `Status`, `Icon`, `Side` |
| `widget-toggler.md` | `Toggler`, `Catalog`, `Style`, `Status` |
| `widget-tooltip.md` | `Tooltip`, `Position` |

## Core types

| File | Covers |
|---|---|
| `element.md` | `Element<'a, Message, Theme, Renderer>`, `Into<Element>` pattern |
| `length.md` | `Length::{Fill, Shrink, Fixed, FillPortion}` |
| `padding.md` | `Padding` struct and constructors |
| `alignment.md` | `Alignment`, `Horizontal`, `Vertical` |

## Runtime

| File | Covers |
|---|---|
| `application.md` | `application()` / `daemon()` builders, settings, font loading |
| `task.md` | `Task<Message>` — none, done, batch, perform, future, stream |
| `subscription.md` | `Subscription<Message>` — run_with, batch, stable identity |
| `window.md` | `window::open`, `close`, `resize`, `Event`, `Id`, `Settings` |
| `keyboard.md` | `Key`, `Modifiers`, `Named` (full variants), `listen`, `on_key_press` |
| `mouse.md` | `mouse::Event`, `Button`, `Cursor`, `Interaction` |
| `events.md` | `event::Event`, `listen`, `listen_with`, `listen_raw` |
| `touch.md` | `touch::Event`, `Finger` |
| `stream.md` | `stream::channel`, `try_channel` |
| `time.md` | `time::every`, `repeat`, `now` |
| `futures.md` | `MaybeSend`, `Stream`, `StreamExt` re-exports |
| `debug.md` | `debug::time`, `time_with`, `enable`, `disable` |
| `system.md` | `system::information` (feature `sysinfo`) |

## Theming

| File | Covers |
|---|---|
| `theme.md` | `Theme`, `Theme::custom`, `Theme::custom_with_fn` |
| `theme-palette.md` | `Palette`, `palette::Extended`, `Background`, `Pair` |
| `catalog.md` | `Catalog` trait — `StyleFn`, `Status`, `Style` |

## Reading strategy

**Building new**: guide → API refs → canonical example → code → gotchas.
**Animated layered UI**: `guide-animated-layout.md` + `guide-animation-debugging.md` first.
**Debugging**: `SKILL.md` rules → guide failure-modes → API gotchas. `container.rs unwrap on None` → `guide-custom-overlays.md`. Animation bugs → `guide-animation-debugging.md`.
**Charts**: chart-specific skill if available.
