---
name: trading-design
description: "Professional trading UI design system. Load when designing or implementing panels, layouts, typography, color, data display, or interactions for trading applications."
license: MIT
user-invocable: true
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
  version: "2.0.0"
tags: [ui]
---

# Professional Trading UI Design

> **Problem with this skill?** Run `kendex report` — it files to the owning repo automatically. Do not hand-file.

Stack-agnostic. Specific colors and pixel values belong in your design system, not here.

## Identity

Sierra Chart / Bloomberg data density, Vercel / Linear dark refinement, ShadCN component composition compressed to trading density. Dark is the design target; other themes are adaptations built on established community palettes (Tokyo Night, Catppuccin, Dracula, Nord, Solarized, Rosé Pine, Gruvbox, One Dark), never invented color schemes.

Rejected: Robinhood whitespace and gamification, TradingView social chrome, crypto-exchange neon, generic-dashboard rounded corners and gradients, and any rendering that feels sluggish under input.

## Density

Default compact; scale up only for readability. A panel that requires scrolling to show its core content has failed. Use a 4px base unit with consistent multiples.

| Element | Target |
|---------|--------|
| Table row height | 20-28px |
| Panel padding | 4-8px |
| Inter-element gap | 2-4px |
| Font size (data) | 11-13px |
| Font size (labels) | 10-12px |
| Icon size | 12-16px |

Hierarchy: primary data (price, P&L) slightly larger at full opacity; secondary (labels, quantities, timestamps) standard size, reduced opacity; tertiary (metadata, IDs) smallest and dimmest.

Emphasize directional color, stale-data indicators, error and disconnect states, and direction icons alongside color. Minimize decorative borders, box shadows, and non-directional color-coded categories. Animate only when the animation carries information (brief flash on price tick: yes; panel slide-in: no); transitions under 100ms.

## Color

**Exactly two chromatic hues**: one positive direction (buy/bid/profit/long), one negative (sell/ask/loss/short). Everything else is a single neutral at graduated opacity. No blue, orange, yellow, or purple in the base palette.

| Neutral opacity | Role |
|---------|------|
| 100% | Primary text, most important non-directional data |
| 70-80% | Secondary text, labels, headers |
| 40-50% | Tertiary text, timestamps, metadata |
| 20-30% | Disabled text, subtle indicators |
| 8-15% | Borders, dividers, row hover tints |
| 3-6% | Subtle background differentiation |

| Directional variant | Opacity | Use |
|---------|---------|-----|
| Full | 100% | Text, icons — primary directional signal |
| Medium | 60-70% | Secondary directional elements |
| Subtle | 30-40% | Directional borders, outlines |
| Tint | 8-12% | Row/cell background tinting |
| Ghost | 3-5% | Hover backgrounds on directional elements |

Opacity, not new color, carries hierarchy, state, and depth: hover is the current color plus a 5-10% neutral overlay, active/selected 10-15%, disabled 30-40%. Reach for an opacity variant before a new hue; if a third color is needed, it is low-saturation, not confusable with directional color, and there is exactly one.

## Surface and elevation

The canvas is near-black (3-6% brightness, not pure `#000000`); data is the brightest thing on screen. No shadows, no gradients; every background maps to one of five levels.

| Level | Name | Where |
|-------|------|-------|
| 0 | Base | App background, gaps between panels |
| 1 | Panel | Panel content areas, header bar, status bar |
| 2 | Raised | Dropdowns, context menus, tooltips, popovers, dialog content |
| 3 | Hover | Row hover, interactive feedback on any surface |
| 4 | Active | Selected row, active tab, pressed button |

Modal backdrops are a semi-transparent black overlay rather than a ladder level. Borders use the neutral at 8-15% where brightness alone is not enough to define a boundary.

Light mode reverses the elevation ladder. Theme switching changes token values only — never layout, density, or information architecture.

## Typography

Two font categories, no third. **Monospace** for headings, labels, navigation, buttons, status, panel titles, badges, and all numeric data. **Sans-serif** for body paragraphs, tooltips, help text, and long-form explanation.

**If it contains a number the user needs to compare or scan, it is monospace.** A "Cancel" button is sans; a `Buy 5 ES @ 4,512.25` button and a `14:32:05` timestamp are mono.

The monospace face must have tabular figures, lining figures, and a clear zero/O distinction at 11px (JetBrains Mono, IBM Plex Mono, Iosevka, Berkeley Mono, Cascadia Code qualify).

**Decimal points align vertically in every numeric column**: right-align with consistent decimal places, tabular figures, non-breaking-space padding where needed. Text left-aligns, header alignment matches its data, and column widths are fixed.

| Size level | Relative | Use |
|-------|--------------|-----|
| Primary | Base + 1-2px | Current price, total P&L, key metric |
| Standard | Base (11-13px) | Quantities, prices, order details |
| Secondary | Base - 1px | Labels, column headers, timestamps |
| Tertiary | Base - 2px | Metadata, IDs, supplementary info |

## Tokens

A raw color value, pixel measurement, or font specification in component code is a review defect. Raw values exist only in token definitions.

Token categories: directional colors (positive, negative), surface levels (surface-base, surface-panel, surface-raised, surface-hover, surface-active), text hierarchy (text-primary through text-disabled), borders (border-default, border-subtle), spacing (space-xs … space-xl), typography (font-ui, font-data, size-primary, size-standard, size-secondary).

Names describe semantic role, not appearance: `color-positive` not `green-500`, `surface-base` not `dark-bg`, `text-secondary` not `small-text`, `border-default` not `gray-border`.

## Layout and panels

Panels tile to fill available space with no gaps — never float. The chart takes the space remaining after other panels claim their minimums; every panel collapses below its minimum useful size; layout state is saved and restored.

| Priority | Panels |
|----------|--------|
| Never collapse | Chart, order entry |
| Last to collapse | Positions, active orders |
| Early collapse | Watchlist, account info, alerts |
| First to collapse | Settings, logs, analytics |

Collapsed panels show compact indicators carrying key counts ("Orders (3)"). The shell is a fixed header bar (24-32px: symbol, account, connection status, global controls), a flexible dockable panel grid, and a fixed status bar (24-32px: system status, latency, clock). Each panel is a header (20-28px: title, actions, collapse/close), its content, and an optional footer for summary data.

| Panel type | Min width | Min height |
|-----------|----------|-----------|
| Chart | 400px | 300px |
| Order entry | 250px | 200px |
| Positions | 300px | 100px |
| Order book | 200px | 200px |
| Watchlist | 200px | 100px |

Below the combined minimums, collapse lowest-priority panels first into compact indicators, then stack remaining panels vertically, then fall back to a tabbed one-panel-at-a-time view. Breakpoints live in the design system, not in component code, and the user can override collapse priorities.

Every panel implements all five states:

| State | Visual pattern |
|-------|---------------|
| Loading, known layout | Skeleton shimmer matching expected content shape |
| Loading, unknown | Centered spinner with context text |
| Empty | Centered icon, helpful text, how to change it |
| Error | Inline banner with actionable message and retry |
| Disconnected | Last data dimmed, stale warning, timestamp |

State transitions are immediate — no fades. Disconnected: all data visible at reduced opacity, stale warning and last-update timestamp visible without scrolling, **order entry disabled**, modification and cancellation enabled, transition from live instant and obvious.

## Data display

- **Price** — monospace, decimal-aligned, direction shown by icon *and* color, absolute and percentage change both present, decimal places consistent per instrument.
- **Position** — "Long"/"Short" badge in directional color, quantity right-aligned, entry price in secondary text, P&L the most prominent number in the row, row tinted at 5-10% of the directional color.
- **Order** — side in directional color; status as pending (neutral), filled (positive flash settling to neutral), rejected (negative), cancelled (dimmed); time priority in secondary text; the cancel action always visible on working orders, never hover-gated.
- **P&L** — directional color plus icon, right-aligned, currency symbol included (`$+1,234.56`), realized and unrealized clearly labelled, daily/total toggle.
- **Stale data** — dimmed with a `Last update: HH:MM:SS` timestamp.
- **Empty cells** — `—`, never blank.

| Alert severity | Behavior | Dismissal |
|----------|----------|-----------|
| Info / fills | Transient toast | Auto-dismiss 3-5s |
| Warning | Non-blocking toast | Timed 10s or manual |
| Error | Prominent | Manual required — errors never auto-dismiss |
| Persistent | Inline banner | Until the condition resolves |

## Interaction

Every action has a keyboard shortcut, discoverable through tooltips and a `?` help overlay. Focus is a high-contrast ring at least 2px wide on every surface level — restyle, never remove — and panels show a focused state. Icon-only buttons get a tooltip naming the action and shortcut, appearing after 300-500ms, disappearing immediately on leave.

Shortcuts to provide: place order, cancel all orders (panic shortcut plus one confirmation keystroke), cancel last order (single shortcut, no confirmation), flatten position, switch symbol (type-ahead from any context), directional panel navigation.

| Action | Confirmation | Details shown |
|--------|----------|---------------|
| Order placement above threshold | Required | Side, quantity, symbol, price, type, estimated cost |
| Position close / flatten | Required | Symbol, P&L, quantity |
| Cancel all orders | Required | Count, symbols affected |
| Modify working order | Context-dependent | Original vs new, highlighted |

A confirmation shows full details, never a bare "Are you sure?". Its primary button carries the action's directional color, cancel is keyboard-accessible, thresholds are configurable, confirmations never nest.

Reject obviously wrong quantities, warn when a limit price is far from market, highlight a symbol that does not match the current chart, emphasize buy vs sell throughout order entry. Cancel is one action away on every working order, orders can be undone before exchange submission, rejection messages name the order's details.

## Components

Compose from existing primitives (text, row, column, button, input) for PriceDisplay, PositionBadge, PnlDisplay, AlertBanner, NumericStepper, SymbolSearch, StatusIndicator, and OrderTicket. Reserve custom rendering (canvas, WebGL, GPU primitives) for charts, high-frequency DOM/order book, heatmaps, volume profiles. If composition holds 60fps at your data volume, compose.

NumericStepper's step size is the instrument tick, accepting keyboard and scroll input within min/max; SymbolSearch is type-ahead with fuzzy matching and recent history; OrderTicket composes a side toggle, quantity stepper, price input, type selector, and directionally-colored submit.

ShadCN compressed for trading: minimal padding (`px-2 py-1` or less) instead of `px-4 py-2`, line-height 1.2-1.3, 11-13px data text instead of 14-16px body, edge-to-edge panels instead of gapped cards, **zero border radius everywhere, no exceptions**, and subtle hover (an opacity shift, not a color change).

## Accessibility and cross-platform

| Element | Minimum ratio | Standard |
|---------|--------------|----------|
| Body text (< 18px) | 4.5:1 | WCAG AA |
| Large text (>= 18px) | 3:1 | WCAG AA |
| Interactive boundaries | 3:1 | WCAG 2.1 |
| Focus indicators | 3:1 | WCAG 2.1 |

Test every text opacity level, especially tertiary and disabled. Focus rings use a high-contrast non-directional accent.

**Never color alone.** A green price change needs an up arrow, a red P&L a down arrow, buy/sell buttons their "Buy"/"Sell" labels, position direction its "Long"/"Short" badge, a status indicator its text label.

Design at 1x (96 DPI) and test at 100%, 125%, 150%, and 200% scaling. Use vector assets. Test font rendering at 11-13px on every target (FreeType, DirectWrite, Core Text). Custom window chrome must support native window management (snap, resize, minimize).
