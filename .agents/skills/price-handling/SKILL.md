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
  version: "1.0.0"
tags: [data]
---

<!-- kendex:project-instructions:start -->
## Project Instructions

Problems with a kendex-owned skill go through `kendex report`; check ownership in the file first.
<!-- kendex:project-instructions:end -->

# Price Handling Patterns

## The price type is `f64`

IEEE 754 double precision. No fixed-point, no decimal types.

Use `i64` fixed-point **only** for a matching engine (bit-exact required), a regulatory audit trail mandating reproducibility, or a settlement system with legal precision requirements. Hybrid: `i64` on the execution hot path, `f64` for display and analytics.

## Never `==` on prices

```rust
use float_cmp::{approx_eq, F64Margin};

pub const PRICE_EPSILON: f64 = 1e-10;  // sub-pipette tolerance

pub fn prices_equal(a: f64, b: f64) -> bool {
    approx_eq!(f64, a, b, epsilon = PRICE_EPSILON, ulps = 4)
}

pub fn price_gte(a: f64, b: f64) -> bool { a > b || prices_equal(a, b) }
pub fn price_lte(a: f64, b: f64) -> bool { a < b || prices_equal(a, b) }
```

## Round only at the boundaries

| Boundary | Rounding |
|---|---|
| Order submission (OrderRequest → broker API) | Round to tick, then validate alignment |
| Display formatting | Round to the symbol's `display_decimals` |
| Market data ingestion (ticks, bars, quotes) | **Never** — preserve full feed precision |
| P&L calculation | **Never** — use raw values |

```rust
pub fn round_to_tick(price: f64, tick_size: f64) -> f64 {
    (price / tick_size).round() * tick_size
}

pub fn validate_tick_alignment(price: f64, tick_size: f64) -> bool {
    prices_equal(price, round_to_tick(price, tick_size))
}
```

Order submission order: round to tick, validate alignment (on failure return an error — never re-round), then format for the broker API if it takes a string.

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
