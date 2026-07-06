---
name: trading-design
description: "Professional trading UI design system. Load when designing or implementing panels, layouts, typography, color, data display, or interactions for trading applications."
license: MIT
user-invocable: true
metadata:
  author: vanillagreen
  source: vstack
  repository: "https://github.com/vanillagreencom/vstack"
  bugs: "https://github.com/vanillagreencom/vstack/issues"
  version: "2.0.0"
---

# Professional Trading UI Design

Stack-agnostic. Does not define specific tokens, colors, or pixel values — those belong in your design system.

## Skill Guidelines

### Design Philosophy

#### Design Identity and Anti-Patterns

The intersection of three qualities:

- **Sierra Chart / Bloomberg Terminal density** — every pixel carries data, multi-panel layouts, no wasted space
- **Vercel / Linear dark refinement** — near-black canvas, restrained palette, typographic precision
- **ShadCN component clarity** — composable, consistent components with clear visual hierarchy, compressed to trading density

The default theme is dark. The system must support user-customizable themes built on established community palettes — not invented color schemes.

**Reference Platforms:**

| Platform | What to Learn |
|----------|--------------|
| Sierra Chart | Extreme data density, configurability, tiling efficiency |
| Bloomberg Terminal | Information architecture at scale, keyboard-driven workflows |
| Trading Technologies (TT) | Order management UX, ladder precision |
| CQG | Clean professional layout, efficient use of screen real estate |
| Vercel Dashboard | Dark aesthetic, typographic hierarchy, restrained color |
| Linear | Dark, dense, keyboard-first |
| ShadCN/ui | Component composition model, consistent design tokens |

**Anti-Patterns:**

| Anti-Pattern | Problem |
|-------------|---------|
| Robinhood aesthetic | Hides complexity behind whitespace, gamifies trading, wastes density |
| TradingView chrome | Too much social chrome dilutes focus |
| Crypto exchange neon | Multiple bright hues make directional color meaningless |
| Generic dashboard look | Rounded corners, large padding, gradients — wastes 40%+ of screen |
| Electron bloat feel | Sluggish rendering, input lag — must feel instant |

#### Density First

Default compact, scale up only for readability. Every element must earn its screen space.

- **Pixel accountability** — decorative elements (gradients, shadows, rounded corners, excessive padding) must justify themselves against the data they displace
- **Simultaneous visibility** — a panel that requires scrolling to show its core content has failed
- **Compact ≠ cramped** — 4px base unit with consistent multiples creates rhythm even at tight spacing

**Benchmarks:**

| Element | Target |
|---------|--------|
| Table row height | 20-28px |
| Panel padding | 4-8px |
| Inter-element gap | 2-4px |
| Font size (data) | 11-13px |
| Font size (labels) | 10-12px |
| Icon size | 12-16px |

**Hierarchy through density:**

- **Primary data** (price, P&L) — slightly larger, full opacity, prominent position
- **Secondary data** (labels, quantities, timestamps) — standard density, reduced opacity
- **Tertiary data** (metadata, IDs) — smallest size, lowest opacity

#### Signal Through Noise

The signal is price action, position state, and order status. Everything else is noise.

**High-value attention spend:**
- Directional color on P&L and price changes
- Stale data indicators
- Error and disconnect states
- Direction icons alongside color (redundant encoding)

**Minimize or eliminate:**
- Decorative borders (1px at low opacity is enough)
- Box shadows (near-black elevation handles depth)
- Animated transitions (instant state changes are faster to process)
- Color-coded categories that aren't directional

**State communication — must be obvious without searching:**

| State | Why |
|-------|-----|
| Connected / disconnected | Trading on stale data causes losses |
| Position direction and P&L | Core awareness at all times |
| Order status | Working, filled, or rejected |
| Data freshness | Stale prices look identical to live without indication |
| Error conditions | Hidden errors lead to missed trades |

**Animation:** Use only when it communicates information otherwise missed. Brief flash on price tick — acceptable. Panel slide-in transitions — not acceptable. Transitions under 100ms.

---

### Visual Language

#### Two-Hue Directional Color

Exactly two chromatic hues: one for positive direction (buy/bid/profit/long), one for negative (sell/ask/loss/short). All other visual variation from a single neutral at graduated opacities. No blue, orange, yellow, purple in the base palette.

**Neutral variation:**

| Opacity | Role |
|---------|------|
| 100% | Primary text, most important non-directional data |
| 70-80% | Secondary text, labels, headers |
| 40-50% | Tertiary text, timestamps, metadata |
| 20-30% | Disabled text, subtle indicators |
| 8-15% | Borders, dividers, row hover tints |
| 3-6% | Subtle background differentiation |

**When you need a third color:**
1. Prefer neutral treatment first — opacity, icons, or position instead of a new hue
2. If truly needed — low saturation, never confused with directional color
3. One additional hue total, not one per semantic

#### Opacity as Primary Visual Variable

Opacity is the primary tool for hierarchy, state, and depth. Not new colors.

| Role | Opacity Approach |
|------|-----------------|
| Background tinting | Directional hue at 5-10% |
| Borders | Neutral at 8-15% |
| Hover states | Current color + 5-10% neutral overlay |
| Active/selected | Current color + 10-15% neutral overlay |
| Disabled elements | Reduce to 30-40% |
| Text hierarchy | Same neutral at 100%, 70%, 45%, 25% |
| Directional backgrounds | Positive/negative hue at 8% for position rows |

**Directional hue variants:**

| Variant | Opacity | Use |
|---------|---------|-----|
| Full | 100% | Text, icons — primary directional signal |
| Medium | 60-70% | Secondary directional elements |
| Subtle | 30-40% | Directional borders, outlines |
| Tint | 8-12% | Row/cell background tinting |
| Ghost | 3-5% | Hover backgrounds on directional elements |

If reaching for a new color value — stop. Can this be achieved with an opacity variant? If yes, use opacity. A new color in the palette is an architectural change.

#### Surface and Elevation

The default canvas is near-black (3-6% brightness, not pure #000000). Data is the brightest thing on screen. Depth comes from a structured elevation system — not shadows, not gradients.

**Elevation ladder (5 levels):**

| Level | Name | Purpose |
|-------|------|---------|
| 0 | Base | App background — deepest layer, visible between panels |
| 1 | Panel | Primary content containers — where data lives |
| 2 | Raised | Cards, menus, dropdowns, popovers |
| 3 | Hover | Interactive feedback — hover state on any surface |
| 4 | Active | Selected/pressed state — highest emphasis background |

**Elevation in context:**

| UI Element | Level |
|-----------|-------|
| App background (gaps between panels) | 0 (Base) |
| Panel content area | 1 (Panel) |
| Header bar, status bar | 1 (Panel) |
| Dropdown menus, context menus | 2 (Raised) |
| Tooltips, popovers | 2 (Raised) |
| Dialog/modal backdrop | Overlay (semi-transparent black) |
| Dialog/modal content | 2 (Raised) |
| Row on hover | 3 (Hover) |
| Selected row, active tab | 4 (Active) |
| Pressed button | 4 (Active) |

**Principles:**
- Every background maps to one of these five levels — no custom backgrounds
- No shadows — elevation through brightness
- No gradients on surfaces
- Borders at low-opacity neutral (8-15%) where brightness alone isn't enough

**Borders:** Use the neutral at very low opacity rather than a distinct border color. Borders define panel boundaries without drawing attention.

**Theming beyond dark:**
- Use established community palettes only — Tokyo Night, Catppuccin, Dracula, Nord, Solarized, Rosé Pine, Gruvbox, One Dark
- Light mode is a supported variant — elevation principles apply in reverse
- All rules still apply regardless of palette: two directional hues, opacity-based variation, density-first
- Dark is the design target — design and test dark first, other themes are adaptations
- Theme switching changes only token values, never layout, density, or information architecture

---

### Typography & Density

#### Dual-Font System

Two font categories. No exceptions. No third font.

| Category | Font Type | Used For |
|----------|-----------|----------|
| **Structural / Identity** | Monospace | Headings, labels, navigation, buttons, status, panel titles, badges, all numeric data |
| **Prose / Description** | Sans-serif | Body paragraphs, tooltips, help text, long-form explanations |

The monospace font must support **tabular figures** (all digits same width), **lining figures** (baseline-aligned), and **clear zero/O distinction at 11px**. Recommended: JetBrains Mono, IBM Plex Mono, Iosevka, Berkeley Mono, Cascadia Code.

**The boundary — where sans meets mono:**

| Element | Font | Reasoning |
|---------|------|-----------|
| "Positions" panel title | Sans | UI label, no numeric content |
| Order quantity "100" | Mono | Numeric, users compare quantities |
| "Cancel" button | Sans | Text action, no numeric content |
| "Buy 5 ES @ 4,512.25" button | Mono | Contains numbers users must verify |
| Timestamp "14:32:05" | Mono | Numeric sequence users scan |

Rule: **if it contains a number the user needs to compare or scan, it's monospace.**

#### Data Alignment and Size Hierarchy

**Decimal alignment** — the single most important typographic rule for trading data. In any numeric column, decimal points must align vertically.

Implementation: right-align numeric columns with consistent decimal places, use tabular figures, pad with non-breaking spaces if needed.

**Size hierarchy:**

| Level | Relative Size | Use |
|-------|--------------|-----|
| Primary | Base + 1-2px | Current price, total P&L, key metric |
| Standard | Base (11-13px) | Most data: quantities, prices, order details |
| Secondary | Base - 1px | Labels, column headers, timestamps |
| Tertiary | Base - 2px | Metadata, IDs, supplementary info |

**Column layout:**
- Right-align all numeric data
- Left-align text data (symbols, names, labels)
- Fixed column widths — columns must not resize when data changes
- Header alignment matches data alignment

#### Semantic Token Architecture

No component should contain a raw color value, pixel measurement, or font specification. All visual properties reference semantic tokens.

| Category | Examples |
|----------|----------|
| Directional colors | positive, negative (bid/ask, buy/sell, profit/loss) |
| Surface levels | surface-base, surface-panel, surface-raised, surface-hover, surface-active |
| Text hierarchy | text-primary, text-secondary, text-tertiary, text-disabled |
| Borders | border-default, border-subtle |
| Spacing | space-xs, space-sm, space-md, space-lg, space-xl |
| Typography | font-ui, font-data, size-primary, size-standard, size-secondary |

**Naming — by semantic role, not appearance:**

| Wrong | Right |
|-------|-------|
| `green-500` | `color-positive` |
| `dark-bg` | `surface-base` |
| `small-text` | `text-secondary` |
| `gray-border` | `border-default` |

In code review, any hardcoded color value, pixel measurement, or font name in component code is a defect. The only place raw values should exist is in the design system's token definition file.

---

### Layout & Panels

#### Panel Architecture and Docking

Professional trading interfaces are modular panel systems, not page layouts.

- **Tiling, not floating** — panels tile to fill available space with no gaps
- **Priority-based space allocation** — the chart gets remaining space after other panels claim minimums
- **Defined minimums** — every panel has a minimum useful size; below it, the panel collapses
- **User-controlled layout** — layout state is saved and restored reliably

**Panel priority ordering:**

| Priority | Panels | Collapse Behavior |
|----------|--------|-------------------|
| Never collapse | Chart, order entry | Core function |
| Last to collapse | Positions, active orders | Active-state awareness |
| Early collapse | Watchlist, account info, alerts | Important but not moment-to-moment |
| First to collapse | Settings, logs, analytics | Reference panels checked periodically |

Collapsed panels show compact indicators with key counts (e.g., "Orders (3)").

**Shell structure:**
1. **Header bar** (fixed, 24-32px) — symbol, account, connection status, global controls
2. **Content area** (flexible) — dockable panel grid
3. **Status bar** (fixed, 24-32px) — system status, latency, clock

**Panel internal structure:**
1. Panel header (20-28px) — title, actions, collapse/close
2. Panel content — primary function
3. Panel footer (optional) — summary data

#### Required Panel States

Every panel must implement all five states:

| State | Visual Pattern |
|-------|---------------|
| **Loading (known layout)** | Skeleton shimmer matching expected content shape |
| **Loading (unknown)** | Centered spinner with context text |
| **Empty** | Centered icon + helpful text + how to change |
| **Error** | Inline banner with actionable message and retry |
| **Disconnected** | Last data grayed/dimmed with stale warning and timestamp |

**Disconnected state requires special attention:**
- All data visible but at reduced opacity
- Stale data warning visible without scrolling — timestamp of last update, reconnection status
- **Order entry disabled** — cannot submit on stale data
- Order modification/cancellation remains enabled
- Transition from live to disconnected must be instant and obvious

State transitions are immediate. No fade animations between states.

#### Responsive Collapse Strategy

When viewport shrinks below combined minimums:

1. Collapse lowest-priority panels first into compact indicators
2. Stack remaining panels vertically
3. At smallest viable size, tabbed view — one panel at a time

**Rules:**
- Chart and order entry never collapse
- Breakpoints defined in design system, not hardcoded
- Collapsed panels show data counts
- Transitions are instant
- User can override collapse priorities

**Minimum panel sizes (reference):**

| Panel Type | Min Width | Min Height |
|-----------|----------|-----------|
| Chart | 400px | 300px |
| Order entry | 250px | 200px |
| Positions | 300px | 100px |
| Order book | 200px | 200px |
| Watchlist | 200px | 100px |

---

### Data Display

#### Trading Data Display Conventions

**Price:**
- Always monospace, decimal-aligned in columns
- Direction indicator: icon + color (never color alone)
- Show both absolute and percentage change
- Consistent decimal places per instrument

**Position:**
- Direction badge ("Long"/"Short" in directional color)
- Quantity in monospace, right-aligned
- Entry price in secondary text
- P&L with directional color + icon — most important number in the row
- Row tint at 5-10% opacity of directional color

**Order:**
- Side indicator with directional color
- All prices and quantities in monospace, right-aligned, decimal-aligned
- Status: pending (neutral), filled (positive flash → neutral), rejected (negative), cancelled (dimmed)
- Cancel action always visible on working orders — no hover required
- Time priority visible in secondary text

**P&L:**
- Directional color + icon
- Monospace, right-aligned
- Include currency symbol ("$+1,234.56")
- Clearly label realized vs unrealized
- Daily/total toggle

**Alerts:**

| Severity | Behavior | Dismissal |
|----------|----------|-----------|
| Info/fills | Transient toast | Auto-dismiss 3-5s |
| Warning | Non-blocking toast | Timed 10s or manual |
| Error | Prominent | Manual required |
| Persistent | Inline banner | Until condition resolves |

Errors must never auto-dismiss.

**General:**
- Stale data — gray out with "Last update: HH:MM:SS" timestamp
- Empty columns — show "—" not blank (blank is ambiguous)
- Loading — skeleton for known layouts, spinner for unknown
- Confirmation dialogs for orders above configurable threshold — show side, quantity, symbol, price, estimated cost

---

### Interaction Design

#### Keyboard-First Interaction

Every critical action must be reachable by keyboard. The mouse is a fallback.

- Every action has a shortcut
- Shortcuts discoverable via tooltips and help overlay (`?`)
- Focus always visible — high-contrast ring on every interactive element
- Focus order follows visual layout
- Escape always cancels

**Trading-specific shortcuts:**

| Action | Pattern |
|--------|---------|
| Place order | Submit current order entry form |
| Cancel all orders | Panic shortcut + one confirmation keystroke |
| Cancel last order | Single shortcut, no confirmation |
| Flatten position | Close all positions in current symbol |
| Switch symbol | Type-ahead from any context |
| Navigate panels | Directional shortcuts between panels |

**Focus management:**
- Focus trap in modals
- Return focus on close to triggering element
- Panels have visible "focused" state (subtle border highlight)

**Tooltips on every icon-only button:** action name + keyboard shortcut. Appear after 300-500ms hover, disappear immediately on leave.

#### Error Prevention and Confirmation

**Confirmation requirements:**

| Action | Required | Details Shown |
|--------|----------|---------------|
| Order placement (above threshold) | Yes | Side, quantity, symbol, price, type, estimated cost |
| Position close/flatten | Yes | Symbol, P&L, quantity |
| Cancel all orders | Yes | Count, symbols affected |
| Modify working order | Context-dependent | Original vs new highlighted |

**Confirmation dialog design:**
- Show full details — "Are you sure?" with no context is useless
- Primary button uses directional color (buy = positive, sell = negative)
- Cancel always available and keyboard-accessible
- No nested confirmations
- Configurable size thresholds

**Prevention over confirmation:**
- Quantity validation — reject obviously wrong quantities
- Price validation — warn on limit price far from market
- Symbol verification — highlight mismatch with current chart
- Side verification — emphasize buy vs sell throughout order entry

**Recovery:**
- Cancel always one action away on every working order
- Undo before exchange submission
- Clear error messages with rejected order details

---

### Component Philosophy

#### Component Design Approach

**Two approaches:**

**Composed** — from existing primitives (text, row, column, button, input). Use for most widgets: PriceDisplay, PositionBadge, PnlDisplay, AlertBanner, NumericStepper, SymbolSearch, StatusIndicator.

**Custom-rendered** — canvas, WebGL, GPU primitives. Use only for performance-critical visualization: charts, DOM/order book with high-frequency updates, heatmaps, volume profiles.

Threshold: if composed maintains 60fps with your data volume, use composition.

**ShadCN model compressed for trading:**

| ShadCN Pattern | Trading Adaptation |
|---------------|-------------------|
| Generous padding (px-4 py-2) | Minimal padding (px-2 py-1 or less) |
| Comfortable line-height | Tight line-height (1.2-1.3) |
| 14-16px body text | 11-13px data text |
| Card-based with gaps | Edge-to-edge panels, minimal gaps |
| Rounded corners | Zero radius on everything — no exceptions |
| Prominent hover states | Subtle hover (opacity shift, not color change) |

**Standard trading widgets:**

| Widget | Key Requirements |
|--------|-----------------|
| PriceDisplay | Monospace, directional color + icon, absolute + percentage change |
| PositionBadge | Direction, quantity, P&L — one dense row |
| PnlDisplay | Monospace, directional color + icon, realized/unrealized |
| NumericStepper | Step size = instrument tick, keyboard + scroll, min/max |
| SymbolSearch | Type-ahead, fuzzy match, recent history |
| StatusIndicator | Color-coded dot + label from tokens |
| AlertBanner | Severity levels, inline or toast, dismiss per severity |
| OrderTicket | Side toggle, quantity stepper, price input, type selector, directional submit |

**Component checklist:**
- All visual values from semantic tokens
- Numeric data in monospace with tabular figures
- Directional data has both color and icon/text indicator
- All five panel states handled
- Keyboard accessible with visible focus
- Tooltips on all icon-only elements
- Tested at target density

---

### Accessibility

#### Accessibility and Cross-Platform

**Contrast requirements:**

| Element | Minimum Ratio | Standard |
|---------|--------------|----------|
| Body text (< 18px) | 4.5:1 | WCAG AA |
| Large text (>= 18px) | 3:1 | WCAG AA |
| Interactive boundaries | 3:1 | WCAG 2.1 |
| Focus indicators | 3:1 | WCAG 2.1 |

Test every text opacity level. Tertiary/disabled text most likely to fail.

**Never color alone — every directional color needs reinforcement:**

| Color Indicator | Required Reinforcement |
|----------------|----------------------|
| Green price change | Up arrow/triangle icon |
| Red P&L | Down arrow/triangle icon |
| Buy/sell button colors | "Buy"/"Sell" text label |
| Position direction | "Long"/"Short" text badge |
| Status indicator | Status text label |

**Focus indicators:**
- Every interactive element, visible against dark background and any surface level
- High-contrast color (accent/brand since it's not directional)
- 2px minimum width
- Never remove for aesthetics — restyle if needed

**Cross-platform rendering:**
- Design at 1x (96 DPI) baseline
- Test at 100%, 125%, 150%, 200% scaling
- Use vector assets — raster blurs at non-integer scales
- Font rendering varies across FreeType/DirectWrite/Core Text — test at 11-13px on all targets
- Custom window chrome must support native window management (snap, resize, minimize)
