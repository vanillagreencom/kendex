# Surface Selection

For **trading charts or dense visualizations** (>1000 primitives/frame), use Shader + Canvas overlay hybrid. If a chart-specific skill is available, load it — it supersedes Q3 below.

## The five surfaces

| Surface | Use when | Skip when |
|---|---|---|
| **Built-in widgets** | Standard UI composition, forms, layouts, dialogs | You need custom visuals, hit-testing, or events the built-ins don't expose |
| **`Canvas`** (`canvas::Program`) | 2D drawing; path-based rendering; small-to-medium primitive counts; static-ish content | >5000 primitives/frame at 60fps, or custom GPU shaders |
| **`Shader`** (`shader::Program`) | GPU-instanced rendering; custom shader effects; 3D; dense real-time data | A handful of paths — Canvas is simpler |
| **Custom `iced::advanced::Widget`** | Persistent Tree state, custom overlays, non-rectangular hit-testing, full event control, composite layout logic | A built-in + `.style(closure)` already solves it |
| **`iced::advanced::overlay::Overlay`** | A floating layer the built-ins (`tooltip`, `float`, `pick_list`) can't express | You can use `stack![base, opaque(modal)]` or built-ins instead |

## Decision tree

### Q1: Standard UI composition (buttons, forms, layouts)?

**Yes** → built-in widgets + `.style(closure)` for custom colors/borders/spacing. Do not write custom widgets.

**No** → Q2.

### Q2: Visual/drawing surface (charts, visualizations, custom graphics)?

**Yes** → Q3.

**No** → Q4.

### Q3: Visual surface — which surface?

**Trading chart or dense market-data visualization → Shader + Canvas overlay hybrid. Load a chart-specific skill if available.**

For non-chart visual surfaces:

Use **Canvas** when:
- Primitives/frame < ~5000
- Update frequency ≤ 60fps or infrequent
- Paths, rectangles, text, fills, strokes
- Want minimal boilerplate

Use **Shader** when:
- Primitives/frame > 5000 or you need instancing
- Continuous 60fps with per-frame GPU uploads
- Custom shader effects (blur, gradients >16 stops, compute)
- Need tight buffer-management control

### Q4: Custom interaction / state / layout logic?

Use **`iced::advanced::Widget`** when:
- Persistent Tree state (hover, drag, animation phase, accumulators)
- Non-rectangular hit-testing
- Composite child widgets with custom layout math
- Event capture the built-ins don't allow

Skip custom Widget when:
- Just styling → built-in + `.style(closure)`
- Just handling clicks → `button.on_press`
- Just handling drags → `mouse_area` wrapping normal content

See `guide-custom-widgets.md`.

### Q5: Floating layer above the rest of the UI?

**First try built-ins:**

| Need | Built-in |
|---|---|
| Simple tooltip | `iced::widget::tooltip` |
| Dropdown menu | `pick_list` / `combo_box` |
| Modal dialog | `stack![base, opaque(modal)]` — see `examples/modal` |
| Drag ghost | `pin` or `float` |
| Context menu | `mouse_area` opening a `stack` layer / `float` |
| Complex popover | `iced::widget::float` |

Only implement `iced::advanced::overlay::Overlay` when none fit. See `guide-custom-overlays.md`.

## Canonical examples per surface

| Example | Surface | Why |
|---|---|---|
| `tour`, `counter`, `todos`, `editor`, `download_progress` | Built-in widgets | Standard UI |
| `custom_widget` | `iced::advanced::Widget` | Teaching example — draw a circle with `fill_quad` |
| `custom_shader` | `shader::Program` | Canonical GPU pipeline reference |
| `custom_quad` | `iced::advanced::Widget` | Custom rounded-quad |
| `geometry` | `iced::advanced::Widget` + `Mesh2D` | Mesh drawing |
| `bezier_tool`, `clock`, `color_palette`, `solar_system`, `the_matrix`, `game_of_life`, `sierpinski_triangle` | `canvas::Program` | 2D drawing fits Canvas cleanly |
| `loading_spinners`, `arc` | Custom Widget + `canvas::Cache` | Animated arcs; loading_spinners is the canonical smooth-arc pattern |
| `loupe` | Custom Widget + overlay | Hover-triggered transform overlay |
| `toast` | Subscription + animated overlay | Notification lifecycle + composite widget with overlay |
| `modal` | `stack` + `opaque` | Modal dialog without custom Overlay |
| `pane_grid` | `pane_grid` built-in | Docking layout |

## Quick rules

1. Built-in + style closure before custom Widget
2. Canvas before Shader for non-chart visuals
3. Charts use Shader + Canvas overlay hybrid
4. `stack + opaque` before custom Overlay
5. If none of the above, use `iced::advanced::Widget`

## See also

- `canvas.md`
- `shader.md`
- `advanced-widget.md`
- `widgets.md`
