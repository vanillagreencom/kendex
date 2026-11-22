---
name: price-handling
description: "Load when comparing, rounding, formatting, or parsing prices, or designing price types."
summary: "f64 price patterns for trading systems: comparing prices, rounding to tick size, formatting for display and broker APIs, parsing market feeds, designing price types."
license: MIT
user-invocable: true
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
tags: [data]
---

# Price Handling Patterns

## Price type

Store prices as `f64`. Use no fixed-point or decimal type.

Use `i64` fixed-point **only** for:

- a matching engine, where results must be bit-exact;
- a regulatory audit trail that mandates reproducibility;
- a settlement system with legal precision requirements.

A hybrid uses `i64` on the execution hot path and `f64` for display and analytics.

## Comparing prices

Never compare prices with `==`. Compare them by the rule of their domain.

| Domain | Comparison |
|---|---|
| Executable prices: limits, order prices, fills | `prices_equal` |
| Tick alignment | `tick_index` |
| Derived summaries: a broker's average or last-fill price | `derived_equal` |
| Raw depth ordering | strict `<` and `>` on the feed values |

Executable prices take no absolute tolerance.

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

## Rounding

Round a price only at these boundaries.

| Boundary | Rounding |
|---|---|
| Order submission (OrderRequest → broker API) | To tick |
| Display formatting | To the symbol's `display_decimals` |
| Market data ingestion (ticks, bars, quotes) | **Never** |
| P&L calculation | **Never** |

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

`PRICE_ULPS` and the quarter-tick cap are defaults a project with a measured need can change.

Submit an order in this order:

1. Round the price to tick.
2. Validate its alignment.
   - On failure, return an error.
   - Never re-round.
3. If the broker API takes a string, format the price for it.

Format with the symbol's precision, never hardcoded decimals (EURUSD 5, AAPL 2, BTC 8):

```rust
format!("{:.1$}", price, symbol.display_decimals as usize)
```

## Symbol metadata

Tick size and display precision belong to the symbol, not to the price value. Never build a `Price { value, decimals }` struct.

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

For the symbol table:

- Load it at subscription setup, on the cold path.
- Key it by symbol ID.
- Re-sync it on reconnect and when the symbol list changes.

## Price newtype

A price newtype is optional. Where you use one:

- Wrap `f64` in a `#[repr(transparent)]` newtype.
- Give it **no `PartialEq`**.
- Test its equality through `prices_equal`.
- Have its constructor `debug_assert!` that the value `is_finite()`.
- Use it for order types.
- Skip it on the market-data hot path.

## Feed ingestion

- Convert each feed value to `f64` where it enters.
- Pass downstream code plain `f64`, whatever the feed source.

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
