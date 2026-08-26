# iced 0.14.0 — Module inventory (from docs.rs)

Source: https://docs.rs/iced/0.14.0/iced/

## Table of contents
- [iced (root)](#iced-root)
- [iced::advanced](#icedadvanced)
- [iced::advanced::widget](#icedadvancedwidget)
- [iced::advanced::widget::tree](#icedadvancedwidgettree)
- [iced::advanced::widget::operation](#icedadvancedwidgetoperation)
- [iced::advanced::widget::text](#icedadvancedwidgettext)
- [iced::advanced::overlay](#icedadvancedoverlay)
- [iced::advanced::layout](#icedadvancedlayout)
- [iced::advanced::layout::flex](#icedadvancedlayoutflex)
- [iced::advanced::renderer](#icedadvancedrenderer)
- [iced::advanced::mouse](#icedadvancedmouse)
- [iced::advanced::mouse::click](#icedadvancedmouseclick)
- [iced::advanced::text](#icedadvancedtext)
- [iced::advanced::text::paragraph](#icedadvancedtextparagraph)
- [iced::advanced::text::editor](#icedadvancedtexteditor)
- [iced::advanced::text::highlighter](#icedadvancedtexthighlighter)
- [iced::advanced::image](#icedadvancedimage)
- [iced::advanced::svg](#icedadvancedsvg)
- [iced::advanced::clipboard](#icedadvancedclipboard)
- [iced::advanced::input_method](#icedadvancedinput_method)
- [iced::advanced::subscription](#icedadvancedsubscription)
- [iced::widget](#icedwidget)
- [iced::widget::canvas](#icedwidgetcanvas)
- [iced::widget::shader](#icedwidgetshader)
- [iced::widget::pane_grid](#icedwidgetpane_grid)
- [iced::widget::* (other submodules)](#icedwidget-other-submodules)
- [iced::keyboard](#icedkeyboard)
- [iced::mouse](#icedmouse)
- [iced::window](#icedwindow)
- [iced::theme](#icedtheme)
- [iced::task](#icedtask)
- [iced::event](#icedevent)
- [iced::application](#icedapplication)
- [iced::animation](#icedanimation)
- [iced::time](#icedtime)
- [iced::clipboard](#icedclipboard)
- [Miscellaneous top-level modules](#miscellaneous-top-level-modules)

---

## `iced` (root)

> iced is a cross-platform GUI library focused on simplicity and type-safety. Inspired by Elm.

### Re-exports

```rust
pub use application::Application;
pub use daemon::Daemon;
pub use iced_futures::futures;
pub use iced_highlighter as highlighter;   // highlighter feature
pub use iced_renderer::wgpu::wgpu;           // wgpu feature
pub use Alignment::Center;
pub use Length::Fill;
pub use Length::FillPortion;
pub use Length::Shrink;
pub use alignment::Horizontal::Left;
pub use alignment::Horizontal::Right;
pub use alignment::Vertical::Bottom;
pub use alignment::Vertical::Top;
```

### Modules
- [`iced::advanced`](https://docs.rs/iced/0.14.0/iced/advanced/index.html) — Leverage advanced concepts like custom widgets. **(feature `advanced`)**
- [`iced::alignment`](https://docs.rs/iced/0.14.0/iced/alignment/index.html) — Align and position widgets.
- [`iced::animation`](https://docs.rs/iced/0.14.0/iced/animation/index.html) — Animate your applications.
- [`iced::application`](https://docs.rs/iced/0.14.0/iced/application/index.html) — Create and run iced applications step by step.
- [`iced::border`](https://docs.rs/iced/0.14.0/iced/border/index.html) — Draw lines around containers.
- [`iced::clipboard`](https://docs.rs/iced/0.14.0/iced/clipboard/index.html) — Access the clipboard.
- [`iced::daemon`](https://docs.rs/iced/0.14.0/iced/daemon/index.html) — Create and run daemons that run in the background.
- [`iced::debug`](https://docs.rs/iced/0.14.0/iced/debug/index.html) — Debug your applications.
- [`iced::event`](https://docs.rs/iced/0.14.0/iced/event/index.html) — Handle events of a user interface.
- [`iced::executor`](https://docs.rs/iced/0.14.0/iced/executor/index.html) — Choose your preferred executor to power your application.
- [`iced::font`](https://docs.rs/iced/0.14.0/iced/font/index.html) — Load and use fonts.
- [`iced::gradient`](https://docs.rs/iced/0.14.0/iced/gradient/index.html) — Colors that transition progressively.
- [`iced::keyboard`](https://docs.rs/iced/0.14.0/iced/keyboard/index.html) — Listen and react to keyboard events.
- [`iced::message`](https://docs.rs/iced/0.14.0/iced/message/index.html) — Traits for the message type of a Program.
- [`iced::mouse`](https://docs.rs/iced/0.14.0/iced/mouse/index.html) — Listen and react to mouse events.
- [`iced::overlay`](https://docs.rs/iced/0.14.0/iced/overlay/index.html) — Display interactive elements on top of other widgets.
- [`iced::padding`](https://docs.rs/iced/0.14.0/iced/padding/index.html) — Space stuff around the perimeter.
- [`iced::stream`](https://docs.rs/iced/0.14.0/iced/stream/index.html) — Create asynchronous streams of data.
- [`iced::system`](https://docs.rs/iced/0.14.0/iced/system/index.html) — Retrieve system information.
- [`iced::task`](https://docs.rs/iced/0.14.0/iced/task/index.html) — Create runtime tasks.
- [`iced::theme`](https://docs.rs/iced/0.14.0/iced/theme/index.html) — Use the built-in theme and styles.
- [`iced::time`](https://docs.rs/iced/0.14.0/iced/time/index.html) — Listen and react to time.
- [`iced::touch`](https://docs.rs/iced/0.14.0/iced/touch/index.html) — Listen and react to touch events.
- [`iced::widget`](https://docs.rs/iced/0.14.0/iced/widget/index.html) — Use the built-in widgets or create your own.
- [`iced::window`](https://docs.rs/iced/0.14.0/iced/window/index.html) — Configure the window of your application in native platforms.

### Macros
- `color` — Creates a `Color` with shorter and cleaner syntax.

### Structs
- `Animation` — The animation of some particular state.
- `Border` — A border.
- `Color` — A color in the sRGB color space.
- `Degrees`
- `Font` — A font.
- `Padding` — An amount of space to pad for each side of a box.
- `Pixels` — An amount of logical pixels.
- `Point` — A 2D point.
- `Preset` — A specific boot strategy for a `Program`.
- `Radians`
- `Rectangle` — An axis-aligned rectangle.
- `Settings` — The settings of an iced program.
- `Shadow` — A shadow.
- `Size` — An amount of space in 2 dimensions.
- `Subscription` — A request to listen to external events.
- `Task` — A set of concurrent actions to be performed by the iced runtime.
- `Transformation` — A 2D transformation matrix.
- `Vector` — A 2D vector.

### Enums
- `Alignment` — Alignment on the axis of a container.
- `Background` — The background of some element.
- `ContentFit` — The strategy used to fit the contents of a widget to its bounding box.
- `Error` — An error that occurred while running an application.
- `Event` — A user interface event.
- `Gradient` — A fill which transitions colors progressively along a direction, either linearly, radially (TBD), or conically (TBD).
- `Length` — The strategy used to fill space in a specific dimension.
- `Never` — The error type for errors that can never happen.
- `Rotation` — The strategy used to rotate the content.
- `Theme` — A built-in theme.

### Traits
- `Executor` — A type that can run futures.
- `Function` — A trait extension for binary functions (`Fn(A, B) -> O`).
- `Program` — An interactive, native, cross-platform, multi-windowed application.
- `Window` — A window managed by iced.

### Functions
- `application` — Creates an iced `Application` given its boot, update, and view logic.
- `daemon` — Creates an iced `Daemon` given its boot, update, and view logic.
- `exit` — Creates a `Task` that exits the iced runtime.
- `never` — A function that can never be called.
- `run` — Runs a basic iced application with default `Settings` given its update and view logic.

### Type Aliases
- `Element<'a, Message, Theme, Renderer>` — A generic widget.
- `Renderer` — The default graphics renderer for iced.
- `Result` — The result of running an iced program.

---

## `iced::advanced`

> Leverage advanced concepts like custom widgets. **(feature `advanced`)**

### Re-exports
```rust
pub use crate::renderer::graphics;
```

### Modules
- `clipboard` — Access the clipboard.
- `image` — Load and draw raster graphics.
- `input_method` — Listen to input method events.
- `layout` — Position your widgets properly.
- `mouse` — Handle mouse events.
- `overlay` — Display interactive elements on top of other widgets.
- `renderer` — Write your own renderer.
- `subscription` — Write your own subscriptions.
- `svg` — Load and draw vector graphics.
- `text` — Draw and interact with text.
- `widget` — Create custom widgets and operate on them.

### Structs
- `Layout` — The bounds of a `Node` and its children, using absolute coordinates.
- `Shell` — A connection to the state of a shell.
- `Text` — A paragraph.

### Enums
- `InputMethod` — The input method strategy of a widget.

### Traits
- `Clipboard` — A buffer for short-term storage and transfer within and between applications.
- `Overlay` — An interactive component that can be displayed on top of other widgets.
- `Renderer` — A component that can be used by widgets to draw themselves on a screen.
- `Widget` — A component that displays information and allows interaction.

---

## `iced::advanced::widget`

> Create custom widgets and operate on them.

### Modules
- `operation` — Query or update internal widget state.
- `text` — Text widgets display information through writing.
- `tree` — Store internal widget state in a state tree to ensure continuity.

### Structs
- `Id` — The identifier of a generic widget.
- `Text` — A bunch of text.
- `Tree` — A persistent state widget tree.

### Traits
- `Operation` — A piece of logic that can traverse the widget tree of an application in order to query or update some widget state.
- `Widget` — A component that displays information and allows interaction.

### Functions
- `operate` — Creates a new `Task` that runs the given `widget::Operation` and produces its output.

---

## `iced::advanced::widget::tree`

> Store internal widget state in a state tree to ensure continuity.

### Structs
- `Tag` — The identifier of some widget state.
- `Tree` — A persistent state widget tree.

### Enums
- `State` — The internal `State` of a widget.

### Functions
- `diff_children_custom_with_search`

---

## `iced::advanced::widget::operation`

> Query or update internal widget state.

### Modules
- `focusable` — Operate on widgets that can be focused.
- `scrollable` — Operate on widgets that can be scrolled.
- `text_input` — Operate on widgets that have text input.

### Enums
- `Outcome` — The result of an `Operation`.

### Traits
- `Focusable` — The internal state of a widget that can be focused.
- `Operation` — A piece of logic that can traverse the widget tree of an application in order to query or update some widget state.
- `Scrollable` — The internal state of a widget that can be scrolled.
- `TextInput` — The internal state of a widget that has text input.

### Functions
- `black_box` — Wraps the `Operation` in a black box, erasing its returning type.
- `map` — Maps the output of an `Operation` using the given function.
- `scope` — Produces an `Operation` that applies the given `Operation` to the children of a container with the given `Id`.
- `then` — Chains the output of an `Operation` with the provided function to build a new `Operation`.

---

## `iced::advanced::widget::text`

> Text widgets display information through writing.

### Structs
- `Format` — The format of some `Text`.
- `Style` — The appearance of some text.
- `Text` — A bunch of text.

### Enums
- `Alignment` — The alignment of some text.
- `LineHeight` — The height of a line of text in a paragraph.
- `Shaping` — The shaping strategy of some text.
- `Wrapping` — The wrapping strategy of some text.

### Traits
- `Catalog` — The theme catalog of a `Text`.

### Functions
- `base` — Text with the default base color.
- `danger` — Text conveying some negative information, like an error.
- `default` — The default text styling; color is inherited.
- `draw` — Draws text using the same logic as the `Text` widget.
- `layout` — Produces the `layout::Node` of a `Text` widget.
- `primary` — Text conveying some important information, like an action.
- `secondary` — Text conveying some secondary information, like a footnote.
- `success` — Text conveying some positive information, like a successful event.
- `warning` — Text conveying some mildly negative information, like a warning.

### Type Aliases
- `State` — The internal state of a `Text` widget.
- `StyleFn` — A styling function for a `Text`.

---

## `iced::advanced::overlay`

> Display interactive elements on top of other widgets.

### Structs
- `Element` — A generic `Overlay`.
- `Group` — An `Overlay` container that displays multiple overlay `overlay::Element` children.
- `Nested` — An overlay container that displays nested overlays.

### Traits
- `Overlay` — An interactive component that can be displayed on top of other widgets.

### Functions
- `from_children` — Returns a `Group` of overlay `Element` children.

---

## `iced::advanced::layout`

> Position your widgets properly.

### Modules
- `flex` — Distribute elements using a flex-based layout.

### Structs
- `Layout` — The bounds of a `Node` and its children, using absolute coordinates.
- `Limits` — A set of size constraints for layouting.
- `Node` — The bounds of an element and its children.

### Functions
- `atomic`
- `contained`
- `next_to_each_other`
- `padded`
- `positioned`
- `sized`

---

## `iced::advanced::layout::flex`

> Distribute elements using a flex-based layout.

### Enums
- `Axis` — The main axis (`Horizontal` or `Vertical`).

### Functions
- `resolve` — Computes the flex layout for a list of items.

---

## `iced::advanced::renderer`

> Write your own renderer.

### Structs
- `Quad` — A polygon with four sides.
- `Style` — The styling attributes of a `Renderer`.

### Traits
- `Headless` — A headless renderer is a renderer that can render offscreen without a window nor a compositor.
- `Renderer` — A component that can be used by widgets to draw themselves on a screen.

---

## `iced::advanced::mouse`

> Handle mouse events.

### Modules
- `click` — Track mouse clicks.

### Structs
- `Click` — A mouse click.

### Enums
- `Button` — The button of a mouse.
- `Cursor` — The mouse cursor state.
- `Event` — A mouse event.
- `Interaction` — The interaction of a mouse cursor.
- `ScrollDelta` — A scroll movement.

---

## `iced::advanced::mouse::click`

> Track mouse clicks.

### Structs
- `Click` — A mouse click.

### Enums
- `Kind` — The kind of a mouse click (`Single`, `Double`, `Triple`).

---

## `iced::advanced::text`

> Draw and interact with text.

### Modules
- `editor` — Edit text.
- `highlighter` — Highlight text.
- `paragraph` — Draw paragraphs.

### Structs
- `Highlight` — A text highlight.
- `Span` — A span of text.
- `Text` — A paragraph.

### Enums
- `Alignment` — The alignment of some text.
- `Difference` — The difference detected in some text.
- `Hit` — The result of hit testing on text.
- `LineHeight` — The height of a line of text in a paragraph.
- `Shaping` — The shaping strategy of some text.
- `Wrapping` — The wrapping strategy of some text.

### Traits
- `Editor` — A component that can be used by widgets to edit multi-line text.
- `Highlighter` — A type capable of highlighting text.
- `IntoFragment` — A trait for converting a value to some text `Fragment`.
- `Paragraph` — A text paragraph.
- `Renderer` — A renderer capable of measuring and drawing `Text`.

### Type Aliases
- `Fragment` — A fragment of `Text`.

---

## `iced::advanced::text::paragraph`

### Structs
- `Plain<P>` — A "plain" `Paragraph` that can be efficiently reshaped.

---

## `iced::advanced::text::editor`

### Enums
- `Action` — An editor action (`Move`, `Select`, `Insert`, `Delete`, `Backspace`, etc.)
- `Direction` — A cursor direction.
- `Motion` — A cursor motion.
- `Edit` — An edit operation.

---

## `iced::advanced::text::highlighter`

### Structs
- `PlainText` — A plain text highlighter (no highlighting).

### Enums
- `Format` — The format of a highlight.

---

## `iced::advanced::image`

> Load and draw raster graphics.

### Structs
- `Allocation` — A memory allocation of a `Handle`, often in GPU memory.
- `Id` — The unique identifier of some `Handle` data.
- `Image` — A raster image that can be drawn.
- `Memory` — Some memory taken by an `Allocation`.

### Enums
- `Error` — An image loading error.
- `FilterMethod` — Image filtering strategy.
- `Handle` — A handle of some image data.

### Traits
- `Renderer` — A `Renderer` that can render raster graphics.

### Functions
- `allocate` *(unsafe)* — Creates a new `Allocation` for the given handle.

---

## `iced::advanced::svg`

> Load and draw vector graphics.

### Structs
- `Handle` — A handle of `Svg` data.
- `Svg` — A raster image that can be drawn.

### Enums
- `Data` — The data of a vectorial image.

### Traits
- `Renderer` — A `Renderer` that can render vector graphics.

---

## `iced::advanced::clipboard`

> Access the clipboard.

### Structs
- `Null` — A null implementation of the `Clipboard` trait.

### Enums
- `Kind` — The kind of `Clipboard`.

### Traits
- `Clipboard` — A buffer for short-term storage and transfer within and between applications.

---

## `iced::advanced::input_method`

> Listen to input method events.

### Structs
- `Preedit` — The pre-edit of an `InputMethod`.

### Enums
- `Event` — Describes input method events.
- `InputMethod` — The input method strategy of a widget.
- `Purpose` — The purpose of an `InputMethod`.

---

## `iced::advanced::subscription`

> Write your own subscriptions.

### Enums
- `Event` — A subscription event.

### Traits
- `Recipe` — The description of a `Subscription`.

### Functions
- `from_recipe` — Creates a `Subscription` from a `Recipe` describing it.
- `into_recipes` — Returns the different recipes of the `Subscription`.

### Type Aliases
- `EventStream` — A stream of runtime events.
- `Hasher` — The hasher used for identifying subscriptions.

---

## `iced::widget`

> Use the built-in widgets or create your own.

### Modules
- `button` — Buttons allow your users to perform actions by pressing them.
- `canvas` — Canvases can be leveraged to draw interactive 2D graphics. **(feature `canvas`)**
- `checkbox` — Checkboxes can be used to let users make binary choices.
- `combo_box` — Combo boxes display a dropdown list of searchable and selectable options.
- `container` — Containers let you align a widget inside their boundaries.
- `float` — Make elements float!
- `grid` — Distribute content on a grid.
- `image` — Images display raster graphics in different formats (PNG, JPG, etc.). **(feature `image`)**
- `keyed` — Keyed widgets can provide hints to ensure continuity.
- `markdown` — Markdown widgets can parse and display Markdown. **(feature `markdown`)**
- `operation` — Change internal widget state.
- `overlay` — Display interactive elements on top of other widgets.
- `pane_grid` — Pane grids let your users split regions of your application and organize layout dynamically.
- `pick_list` — Pick lists display a dropdown list of selectable options.
- `progress_bar` — Progress bars visualize the progression of an extended computer operation.
- `qr_code` — QR codes display information in a type of two-dimensional matrix barcode. **(feature `qr_code`)**
- `radio` — Radio buttons let users choose a single option from a bunch of options.
- `row` — Distribute content horizontally.
- `rule` — Rules divide space horizontally or vertically.
- `scrollable` — Scrollables let users navigate an endless amount of content with a scrollbar.
- `selector` — Find and query widgets in your applications. **(feature `selector`)**
- `sensor` — Generate messages when content pops in and out of view.
- `shader` — A custom shader widget for wgpu applications. **(feature `wgpu`)**
- `slider` — Sliders let users set a value by moving an indicator.
- `space` — Add some explicit spacing between elements.
- `svg` — Svg widgets display vector graphics in your application. **(feature `svg`)**
- `table` — Display tables.
- `text` — Draw and interact with text.
- `text_editor` — Text editors display a multi-line text input for text editing.
- `text_input` — Text inputs display fields that can be filled with text.
- `theme` — Use the built-in theme and styles.
- `toggler` — Togglers let users make binary choices by toggling a switch.
- `tooltip` — Tooltips display a hint of information over some element when hovered.
- `vertical_slider` — Sliders let users set a value by moving an indicator.

### Macros
- `column` — Creates a `Column` with the given children.
- `grid` — Creates a `Grid` with the given children.
- `keyed_column` — Creates a keyed `Column` with the given children.
- `rich_text` — Creates some `Rich` text with the given spans.
- `row` — Creates a `Row` with the given children.
- `stack` — Creates a `Stack` with the given children.
- `text` — Creates a new `Text` widget with the provided content.

### Structs
`Action`, `Button`, `Canvas`, `Checkbox`, `Column`, `ComboBox`, `Container`, `Float`, `Grid`, `Id`, `Image`, `Lazy` *(feature `lazy`)*, `MouseArea`, `PaneGrid`, `PickList`, `Pin`, `ProgressBar`, `QRCode` *(feature `qr_code`)*, `Radio`, `Responsive`, `Row`, `Rule`, `Scrollable`, `Sensor`, `Shader` *(feature `wgpu`)*, `Slider`, `Space`, `Stack`, `Svg` *(feature `svg`)*, `TextEditor`, `TextInput`, `Themer`, `Toggler`, `Tooltip`, `VerticalSlider`.

### Enums
- `Theme` — A built-in theme.

### Traits
- `Component` *(deprecated, feature `lazy`)* — A reusable, custom widget that uses The Elm Architecture.

### Functions (widget constructors)
`bottom`, `bottom_center`, `bottom_right`, `button`, `canvas` *(feature `canvas`)*, `center`, `center_x`, `center_y`, `checkbox`, `column`, `combo_box`, `component` *(deprecated, feature `lazy`)*, `container`, `float`, `grid`, `hover`, `iced` *(the logo)*, `image` *(feature `image`)*, `keyed_column`, `lazy` *(feature `lazy`)*, `markdown` *(feature `markdown`)*, `mouse_area`, `opaque`, `pane_grid`, `pick_list`, `pin`, `progress_bar`, `qr_code` *(feature `qr_code`)*, `radio`, `responsive`, `rich_text`, `right`, `right_center`, `row`, `scrollable`, `sensor`, `shader` *(feature `wgpu`)*, `slider`, `space`, `span`, `stack`, `svg` *(feature `svg`)*, `table`, `text`, `text_editor`, `text_input`, `themer`, `toggler`, `tooltip`, `value`, `vertical_slider`.

### Type Aliases
- `Renderer` — The default graphics renderer for iced.
- `Text` — A bunch of text.

---

## `iced::widget::canvas`

> Canvases can be leveraged to draw interactive 2D graphics. **(feature `canvas`)**

### Modules
- `fill` — Fill `Geometry` with a certain style.
- `gradient` — A gradient that can be used as a fill for some geometry.
- `path` — Build different kinds of 2D shapes.
- `stroke` — Create lines from a `Path` and assigns them various attributes/styles.

### Structs
- `Action` — A runtime action that can be performed by some widgets.
- `Canvas` — A widget capable of drawing 2D graphics.
- `Fill` — The style used to fill geometry.
- `Group` — A cache group.
- `Image` — A raster image that can be drawn.
- `LineDash` — The dash pattern used when stroking the line.
- `Path` — An immutable set of points that may or may not be connected.
- `Stroke` — The style of a stroke.
- `Text` — A bunch of text that can be drawn to a canvas.

### Enums
- `Event` — A user interface event.
- `Gradient` — A fill which linearly interpolates colors along a direction.
- `LineCap` — The shape used at the end of open subpaths when they are stroked.
- `LineJoin` — The shape used at the corners of paths or basic shapes when they are stroked.
- `Style` — The coloring style of some drawing.

### Traits
- `Program` — The state and logic of a `Canvas`.

### Type Aliases
- `Cache` — A simple cache that stores generated `Geometry` to avoid recomputation.
- `Frame` — The frame supported by a renderer.
- `Geometry` — The geometry supported by a renderer.

---

## `iced::widget::shader`

> A custom shader widget for wgpu applications. **(feature `wgpu`)**

### Structs
- `Action` — A runtime action that can be performed by some widgets.
- `Shader` — A widget which can render custom shaders with Iced's wgpu backend.
- `Storage` — Stores custom, user-provided types.
- `Viewport` — A viewing region for displaying computer graphics.

### Traits
- `Pipeline` — The pipeline of a graphics `Primitive`.
- `Primitive` — A set of methods which allows a `Primitive` to be rendered.
- `Program` — The state and logic of a `Shader` widget.

---

## `iced::widget::pane_grid`

> Pane grids let your users split regions of your application and organize layout dynamically.

### Modules
- `state` — The state of a `PaneGrid`.

### Structs
- `Content`, `Controls`, `Highlight`, `Line`, `Pane`, `PaneGrid`, `ResizeEvent`, `Split`, `State`, `Style`, `TitleBar`

### Enums
- `Axis`, `Configuration`, `Direction`, `DragEvent`, `Edge`, `Node`, `Region`, `Target`

### Traits
- `Catalog`, `Draggable`

### Functions
- `default` — The default style of a `PaneGrid`.

### Type Aliases
- `StyleFn` — A styling function for a `PaneGrid`.

---

## `iced::widget::*` (other submodules)

Every widget submodule follows a similar pattern: a main struct `Foo`, a constructor function `foo()`, a `Style` struct, a `Catalog` trait implementation on `Theme`, and style variants (`primary`, `secondary`, etc.). Below is a summary of each:

### `iced::widget::button`
- Structs: `Button`, `Status`, `Style`
- Enums: `Status` — `Active`, `Hovered`, `Pressed`, `Disabled`
- Trait: `Catalog`
- Functions: `button`, `primary`, `secondary`, `success`, `danger`, `text`
- Type aliases: `StyleFn`

### `iced::widget::checkbox`
- Structs: `Checkbox`, `Icon`, `Style`
- Enums: `Status`
- Trait: `Catalog`
- Functions: `checkbox`, `primary`, `secondary`, `success`, `danger`
- Type aliases: `StyleFn`

### `iced::widget::container`
- Structs: `Container`, `Style`
- Trait: `Catalog`
- Functions: `container`, `transparent`, `rounded_box`, `bordered_box`, `dark`, `background`
- Type aliases: `StyleFn`

### `iced::widget::text_input`
- Structs: `TextInput`, `Style`, `State`, `Value`
- Enums: `Status`, `Side`
- Trait: `Catalog`
- Functions: `text_input`, `default`
- Type aliases: `StyleFn`

### `iced::widget::text_editor`
- Structs: `TextEditor`, `Style`, `Binding`, `Content`, `KeyPress`
- Enums: `Action`, `Edit`, `Motion`, `Status`
- Trait: `Catalog`
- Functions: `text_editor`, `default`, `highlight`
- Type aliases: `StyleFn`

### `iced::widget::scrollable`
- Structs: `Scrollable`, `Style`, `Scrollbar`, `Rail`, `Scroller`, `AbsoluteOffset`, `RelativeOffset`, `Viewport`
- Enums: `Direction`, `Status`, `Anchor`
- Trait: `Catalog`
- Functions: `scrollable`, `default`
- Type aliases: `StyleFn`

### `iced::widget::slider`
- Structs: `Slider`, `Style`, `Rail`, `Handle`
- Enums: `Status`, `HandleShape`
- Trait: `Catalog`
- Functions: `slider`, `default`
- Type aliases: `StyleFn`

### `iced::widget::vertical_slider`
- Structs: `VerticalSlider`
- Functions: `vertical_slider`

### `iced::widget::pick_list`
- Structs: `PickList`, `Style`
- Enums: `Status`, `Handle`
- Trait: `Catalog`
- Functions: `pick_list`, `default`
- Type aliases: `StyleFn`

### `iced::widget::combo_box`
- Structs: `ComboBox`, `State`
- Trait: `Catalog`
- Functions: `combo_box`

### `iced::widget::progress_bar`
- Structs: `ProgressBar`, `Style`
- Trait: `Catalog`
- Functions: `progress_bar`, `primary`, `secondary`, `success`, `danger`
- Type aliases: `StyleFn`

### `iced::widget::radio`
- Structs: `Radio`, `Style`
- Enums: `Status`
- Trait: `Catalog`
- Functions: `radio`, `default`
- Type aliases: `StyleFn`

### `iced::widget::rule`
- Structs: `Rule`, `Style`
- Enums: `FillMode`
- Trait: `Catalog`
- Functions: `horizontal`, `vertical`, `default`
- Type aliases: `StyleFn`

### `iced::widget::toggler`
- Structs: `Toggler`, `Style`
- Enums: `Status`
- Trait: `Catalog`
- Functions: `toggler`, `default`
- Type aliases: `StyleFn`

### `iced::widget::tooltip`
- Structs: `Tooltip`, `Style`
- Enums: `Position`
- Trait: `Catalog`
- Functions: `tooltip`, `default`
- Type aliases: `StyleFn`

### `iced::widget::svg`
- Structs: `Svg`, `Handle`, `Style`
- Enums: `Status`
- Trait: `Catalog`
- Functions: `svg`, `default`
- Type aliases: `StyleFn`

### `iced::widget::image`
- Structs: `Image`, `Handle`, `Viewer`
- Enums: `FilterMethod`, `ContentFit`
- Functions: `image`, `viewer`

### `iced::widget::text`
- Structs: `Text`, `Span`, `Rich`
- Enums: `LineHeight`, `Shaping`, `Wrapping`, `Alignment`
- Functions: `text`, `value`, `rich_text`, `span`

### `iced::widget::table`
- Structs: `Table`, `Column`, `Header`, `Row`, `Separator`, `Style`
- Trait: `Catalog`
- Functions: `table`, `column`, `header`, `row`

### `iced::widget::grid`
- Structs: `Grid`, `Strategy`
- Functions: `grid`
- Macros: `grid`

### `iced::widget::row` / `iced::widget::column`
- Structs: `Row`, `Column`, `Wrapping`
- Functions: `row`, `column`, `with_children`, `wrapping_row`
- Macros: `row`, `column`

### `iced::widget::stack` / `iced::widget::float` / `iced::widget::pin`
- Structs: `Stack`, `Float`, `Pin`
- Functions: `stack`, `float`, `pin`
- Macros: `stack`

### `iced::widget::space`
- Structs: `Space`
- Functions: `space`, `horizontal`, `vertical`, `with_width`, `with_height`

### `iced::widget::mouse_area`
- Structs: `MouseArea`
- Enums: `Interaction`
- Functions: `mouse_area`

### `iced::widget::sensor`
- Structs: `Sensor`
- Enums: `Key`
- Functions: `sensor`

### `iced::widget::qr_code`
- Structs: `QRCode`, `Data`, `Style`
- Enums: `ErrorCorrection`, `Version`
- Trait: `Catalog`

### `iced::widget::markdown`
- Structs: `Settings`, `Style`
- Enums: `Item`, `Span`
- Trait: `Catalog`
- Functions: `parse`, `view`, `default`

### `iced::widget::keyed`
- Structs: `Column`
- Functions: `column`

### `iced::widget::overlay`
- Modules: `menu`

### `iced::widget::operation`
- Enums: `Outcome`
- Traits: `Operation`, `Focusable`, `Scrollable`, `TextInput`

### `iced::widget::theme`
- Re-export of `iced::theme`

### `iced::widget::selector`
- Provides query/find helpers for widgets (by id, by text, by type). Feature `selector`.

---

## `iced::keyboard`

> Listen and react to keyboard events.

### Modules
- `key` — Identify keyboard keys.

### Structs
- `Modifiers` — The current state of the keyboard modifiers.

### Enums
- `Event` — A keyboard event.
- `Key` — A key on the keyboard.
- `Location` — The location of a key on the keyboard.

### Functions
- `listen` — Returns a `Subscription` that listens to ignored keyboard events.

---

## `iced::keyboard::key`

> Identify keyboard keys.

### Enums
- `Code` — Code representing the location of a physical key.
- `Key` — A key on the keyboard.
- `Named` — A named key.
- `NativeCode` — Contains the platform-native physical key identifier.
- `Physical` — Represents the location of a physical key.

---

## `iced::mouse`

> Listen and react to mouse events.

### Enums
- `Button` — The button of a mouse.
- `Cursor` — The mouse cursor state.
- `Event` — A mouse event.
- `Interaction` — The interaction of a mouse cursor.
- `ScrollDelta` — A scroll movement.

(Thin re-export of `iced::advanced::mouse` types.)

---

## `iced::window`

> Configure the window of your application in native platforms.

### Modules
- `icon` — Attach an icon to the window of your application.
- `raw_window_handle` — Interoperability library for Rust Windowing applications.
- `screenshot` — Take screenshots of a window.
- `settings` — Configure your windows.

### Structs
- `Icon`, `Id`, `Screenshot`, `Settings`

### Enums
- `Action`, `Direction`, `Event`, `Level`, `Mode`, `Position`, `RedrawRequest`, `UserAttention`

### Traits
- `Window`

### Functions
`allow_automatic_tabbing`, `close`, `close_events`, `close_requests`, `disable_mouse_passthrough`, `drag`, `drag_resize`, `enable_mouse_passthrough`, `events`, `frames`, `gain_focus`, `is_maximized`, `is_minimized`, `latest`, `maximize`, `minimize`, `mode`, `monitor_size`, `move_to`, `oldest`, `open`, `open_events`, `position`, `raw_id`, `request_user_attention`, `resize`, `resize_events`, `run`, `scale_factor`, `screenshot`, `set_icon`, `set_level`, `set_max_size`, `set_min_size`, `set_mode`, `set_resizable`, `set_resize_increments`, `show_system_menu`, `size`, `toggle_decorations`, `toggle_maximize`

---

## `iced::theme`

> Use the built-in theme and styles.

### Modules
- `palette` — The color palettes of the built-in themes.

### Structs
- `Custom`, `Palette`, `Style`

### Enums
- `Mode`, `Theme`

### Traits
- `Base`

### Functions
- `default`

---

## `iced::task`

> Create runtime tasks.

### Structs
- `Handle` — A handle to a `Task` that can be used for aborting it.
- `Task` — A set of concurrent actions to be performed by the iced runtime.

### Traits
- `Sipper` *(feature `sipper`)* — A sipper is both a `Stream` that produces a bunch of progress and a `Future` that produces some final output.
- `Straw` *(feature `sipper`)* — A `Straw` is a `Sipper` that can fail.

### Functions
- `sipper` *(feature `sipper`)*
- `stream` *(feature `sipper`)*

### Type Aliases
- `Never` *(feature `sipper`)* — A type with no possible values.

---

## `iced::event`

> Handle events of a user interface.

### Enums
- `Event` — A user interface event.
- `Status` — The status of an `Event` after being processed.

### Functions
- `listen` — Returns a `Subscription` to all the ignored runtime events.
- `listen_raw` — Creates a `Subscription` that produces a message for every runtime event, including the redraw request events.
- `listen_with` — Creates a `Subscription` that listens and filters all the runtime events with the provided function, producing messages accordingly.

---

## `iced::application`

> Create and run iced applications step by step.

### Re-exports
```rust
pub use timed::timed;
```

### Modules
- `timed` — An Application that receives an `Instant` in update logic.

### Structs
- `Application` — The underlying definition and configuration of an iced application.

### Traits
- `BootFn` — The logic to initialize the `State` of some `Application`.
- `IntoBoot` — The initial state of some `Application`.
- `ThemeFn` — The theme logic of some `Application`.
- `TitleFn` — The title logic of some `Application`.
- `UpdateFn` — The update logic of some `Application`.
- `ViewFn` — The view logic of some `Application`.

### Functions
- `application` — Creates an iced `Application` given its boot, update, and view logic.

---

## `iced::animation`

> Animate your applications.

### Structs
- `Animation` — The animation of some particular state.

### Enums
- `Easing`

### Traits
- `Float` — Defines a float representation for arbitrary types.
- `Interpolable` — A type implementing `Interpolable` can be used with `Animated<T>.animate(...)`.

---

## `iced::time`

> Listen and react to time.

### Structs
- `Duration`, `Instant`, `SystemTime`

### Functions
- `days`, `hours`, `minutes`, `seconds`, `milliseconds`
- `every` *(feature `tokio`, `smol`, or WebAssembly)*
- `now`
- `repeat` *(feature `tokio`, `smol`, or WebAssembly)*

---

## `iced::clipboard`

> Access the clipboard.

### Functions
- `read` — Read the current contents of the clipboard.
- `read_primary` — Read the current contents of the primary clipboard.
- `write` — Write the given contents to the clipboard.
- `write_primary` — Write the given contents to the primary clipboard.

---

## Miscellaneous top-level modules

### `iced::alignment`
- Enums: `Horizontal`, `Vertical`, `Alignment`

### `iced::border`
- Structs: `Border`, `Radius`
- Functions: `rounded`, `width`, `color`

### `iced::font`
- Structs: `Font`
- Enums: `Family`, `Stretch`, `Style`, `Weight`
- Functions: `load`
- Constants: `DEFAULT` (`Font` constant)

### `iced::gradient`
- Structs: `Linear`, `ColorStop`
- Enums: `Gradient`

### `iced::padding`
- Functions: `all`, `top`, `right`, `bottom`, `left`, `horizontal`, `vertical`
- Struct: re-export of `Padding`

### `iced::touch`
- Enums: `Event`, `Finger`
- Structs: `Touch`

### `iced::executor`
- Struct: `Default`

### `iced::debug`
- Functions: `hot`, `draw`, `log`, `toggle`
- Structs: `Frame`, `Span`

### `iced::stream`
- Functions: `channel`, `sipper` *(feature `sipper`)*, `try_channel`

### `iced::system`
- Structs: `Information`
- Functions: `fetch_information`

### `iced::daemon`
- Structs: `Daemon`
- Functions: `daemon`

### `iced::message`
- Traits: `Message` — Marker trait for `'static + MaybeSend + MaybeDebug`.

### `iced::overlay`
- Re-export of `iced::advanced::overlay` basics.
