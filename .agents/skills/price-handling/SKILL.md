---
name: price-handling
description: "Load when comparing, rounding, formatting, or parsing prices, or designing price types."
license: MIT
user-invocable: true
metadata:
  author: "vanillagreen"
  source: "kendex"
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
---

<!-- kendex:project-instructions:start -->
## Project Instructions

<!-- kendex:shared-instructions:start -->
Problems with a kendex-owned skill go through `kendex report`; check ownership in the file first.
<!-- kendex:shared-instructions:end -->
<!-- kendex:project-instructions:end -->

# Price Handling Patterns

## The price type is `f64`

IEEE 754 double precision. No fixed-point, no decimal types.

Use `i64` fixed-point **only** for a matching engine (bit-exact required), a regulatory audit trail mandating reproducibility, or a settlement system with legal precision requirements. Hybrid: `i64` on the execution hot path, `f64` for display and analytics.

## Never `==` on prices

Each comparison domain takes its own rule. An absolute tolerance collapses every tick finer than itself, so no single epsilon serves all prices.

| Domain | Comparison |
|---|---|
| Executable prices: limits, order prices, fills | `prices_equal`: at most four representable doubles (ULPs) apart, no absolute tolerance |
| Tick alignment | `tick_index`: the nearest tick count, admitting representation noise capped at a quarter tick |
| Derived summaries: a broker's average or last-fill price | `derived_equal`, with a relative tolerance the project chooses |
| Raw depth ordering | strict `<` and `>` on the feed values |

```rust
/// Representable doubles (ULPs) an executable price may drift from its value.
pub const PRICE_ULPS: u64 = 4;

/// Representable doubles between two prices, counted across zero.
fn ulps_between(a: f64, b: f64) -> u64 {
    // Map each double to an integer that orders like the double.
    let key = |x: f64| match x.to_bits() as i64 {
        bits if bits < 0 => i64::MIN - bits,
        bits => bits,
    };
    key(a).abs_diff(key(b))
}

/// Executable prices: equal when at most `PRICE_ULPS` representable doubles apart.
pub fn prices_equal(a: f64, b: f64) -> bool {
    if a == b {
        return true; // also +0.0 against -0.0
    }
    if !a.is_finite() || !b.is_finite() || a.is_sign_negative() != b.is_sign_negative() {
        return false;
    }
    ulps_between(a, b) <= PRICE_ULPS
}

pub fn price_gte(a: f64, b: f64) -> bool { a > b || prices_equal(a, b) }
pub fn price_lte(a: f64, b: f64) -> bool { a < b || prices_equal(a, b) }

/// Derived summaries: `rel_tol` is the project's constant, scaled by the
/// larger magnitude.
pub fn derived_equal(a: f64, b: f64, rel_tol: f64) -> bool {
    prices_equal(a, b) || (a - b).abs() <= rel_tol * a.abs().max(b.abs())
}
```

## Round only at the boundaries

| Boundary | Rounding |
|---|---|
| Order submission (OrderRequest → broker API) | Round to tick, then validate alignment |
| Display formatting | Round to the symbol's `display_decimals` |
| Market data ingestion (ticks, bars, quotes) | **Never**. Preserve full feed precision |
| P&L calculation | **Never**. Use raw values |

```rust
pub fn round_to_tick(price: f64, tick_size: f64) -> f64 {
    (price / tick_size).round() * tick_size
}

/// The tick count of an aligned price. None when the price is off-grid, an
/// input is not finite, or neighbouring ticks at this magnitude are too few
/// doubles apart for `prices_equal` to tell their prices apart.
pub fn tick_index(price: f64, tick_size: f64) -> Option<f64> {
    if !(price.is_finite() && tick_size.is_finite() && tick_size > 0.0) {
        return None;
    }
    let n = (price / tick_size).round();
    let (below, at, above) = ((n - 1.0) * tick_size, n * tick_size, (n + 1.0) * tick_size);
    // Each accepted price lies within PRICE_ULPS of its tick, so neighbours more
    // than three allowances away keep prices on adjacent ticks more than one
    // allowance apart, whatever the quarter-tick cap is set to.
    let floor = 3 * PRICE_ULPS;
    if !(ulps_between(below, at) > floor && ulps_between(at, above) > floor) {
        return None;
    }
    // Representation noise is admitted, capped at a quarter tick.
    (prices_equal(price, at) && (price - at).abs() <= tick_size / 4.0).then_some(n)
}

pub fn validate_tick_alignment(price: f64, tick_size: f64) -> bool {
    tick_index(price, tick_size).is_some()
}
```

Prices that `tick_index` accepts on two different ticks never compare equal: it refuses a grid whose neighbouring ticks lie twelve or fewer representable doubles apart, three times the four-ULP allowance. Real grids clear that floor by far: BTC at 1e5 with a 1e-8 tick has 687 doubles between ticks. `PRICE_ULPS` and the quarter-tick cap are defaults a project with a measured need can change, and the floor follows `PRICE_ULPS`; the relative tolerance is the project's own constant.

Order submission order: round to tick, validate alignment (on failure return an error, never re-round), then format for the broker API if it takes a string.

Format with the symbol's precision, never hardcoded decimals (EURUSD 5, AAPL 2, BTC 8):

```rust
format!("{:.1$}", price, symbol.display_decimals as usize)
```

## Symbol metadata owns precision

Tick size and display precision belong to the symbol, not to the price value. A `Price { value, decimals }` struct is the wrong shape.

```rust
#[derive(Clone, Copy)]
pub struct SymbolSpec {
    pub symbol_id: u32,
    pub tick_size: f64,         // minimum price increment
    pub display_decimals: u8,   // decimal places for UI
    pub lot_size: f64,          // minimum quantity
}

impl SymbolSpec {
    pub fn round_price(&self, price: f64) -> f64 {
        round_to_tick(price, self.tick_size)
    }

    pub fn format_price(&self, price: f64) -> String {
        format!("{:.1$}", price, self.display_decimals as usize)
    }
}
```

The symbol table loads at subscription setup (cold path), is keyed by symbol ID, and re-syncs on reconnect or symbol list change.

## Price newtype

Optional: wrap `f64` in a `#[repr(transparent)]` newtype with `PartialOrd` but **no `PartialEq`**; equality goes through `prices_equal`. Constructor `debug_assert!`s `is_finite()`. Use for order types; skip on the market-data hot path.

## Normalize feeds to `f64` at ingest

Convert at the entry boundary; downstream code sees plain `f64` regardless of feed source.

```rust
// doubles (IB, dxFeed, Rithmic): pass through
fn ingest_double(value: f64) -> f64 { value }

// strings (Binance, Coinbase): parse
fn ingest_string(s: &str) -> Result<f64, ParseFloatError> { s.parse() }

// scaled integers (CME MDP): unscale
fn ingest_scaled(mantissa: i64, exponent: i8) -> f64 {
    mantissa as f64 * 10f64.powi(exponent as i32)
}
```
