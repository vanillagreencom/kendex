---
name: price-handling
description: "f64 price patterns for trading systems. Load when: comparing prices, rounding to tick size, formatting for display/broker APIs, parsing market feeds, designing price types or SymbolSpec structs."
license: MIT
user-invocable: true
metadata:
  author: vanillagreen
  source: vstack
  repository: "https://github.com/vanillagreencom/vstack"
  bugs: "https://github.com/vanillagreencom/vstack/issues"
  version: "1.0.0"
---

# Price Handling Patterns

> **Problem with this skill?** Run `vstack report` — it files to the owning repo automatically. Do not hand-file.

f64 price handling rules for trading systems -- epsilon comparison, tick-size rounding, feed normalization, and display formatting.

## Resources

### ctx7 CLI

| Library | ctx7 ID | Use For |
|---------|---------|---------|
| Rust std | `/websites/doc_rust-lang_stable_std` | f64 methods, parse, formatting |

## Skill Rules

### Core Rules

Non-negotiable f64 price handling constraints.

#### f64 for All Prices

IEEE 754 double-precision (`f64`) is the standard price type. No fixed-point, no decimal types.

Rationale: Industry standard (MT5, NinjaTrader, MultiCharts), 15-17 significant digits, SIMD-friendly, zero-overhead newtypes possible.

Migrate to `i64` fixed-point **only if**:
- Building a matching engine (bit-exact required)
- Regulatory audit trail mandates reproducibility
- Settlement system with legal precision requirements

Hybrid approach: `i64` for execution hot path, `f64` for display/analytics.

#### Epsilon Comparison

f64 comparison bugs are the #1 source of price-related issues. Never use `==` on prices.

**Incorrect (direct equality):**

```rust
if price == target {
    execute_order();
}
```

**Correct (epsilon comparison):**

```rust
use float_cmp::{approx_eq, F64Margin};

pub const PRICE_EPSILON: f64 = 1e-10;  // Sub-pipette tolerance

pub fn prices_equal(a: f64, b: f64) -> bool {
    approx_eq!(f64, a, b, epsilon = PRICE_EPSILON, ulps = 4)
}

pub fn price_gte(a: f64, b: f64) -> bool {
    a > b || prices_equal(a, b)
}

pub fn price_lte(a: f64, b: f64) -> bool {
    a < b || prices_equal(a, b)
}
```

#### Tick-Size Rounding

Round prices to valid tick increments. Validate alignment after rounding.

```rust
pub fn round_to_tick(price: f64, tick_size: f64) -> f64 {
    (price / tick_size).round() * tick_size
}

pub fn validate_tick_alignment(price: f64, tick_size: f64) -> bool {
    let rounded = round_to_tick(price, tick_size);
    prices_equal(price, rounded)
}
```

Where rounding applies is governed by the boundary rules below.

### Boundaries

Where and when to round, validate, or format prices. Rounding at the wrong boundary silently destroys feed precision or submits invalid orders.

#### Round at Order Submission

All price rounding and validation converges at the order submission boundary (OrderRequest to broker API).

```rust
pub fn prepare_order(
    request: &OrderRequest,
    symbol: &SymbolSpec,
) -> Result<ValidatedOrder, OrderError> {
    // 1. Round price to tick
    let price = symbol.round_price(request.limit_price);

    // 2. Validate alignment (should be no-op after rounding)
    if !validate_tick_alignment(price, symbol.tick_size) {
        return Err(OrderError::InvalidTickSize);
    }

    // 3. Format for broker API (if string required)
    let price_str = symbol.format_price(price);

    Ok(ValidatedOrder { price, price_str, /* ... */ })
}
```

#### Never Round Market Data

Market data prices must preserve full feed precision. Do not round ticks, bars, or quotes at ingestion. Rounding belongs at the order submission boundary and display formatting only.

**Incorrect (rounding at ingest):**

```rust
tick.price = round_to_tick(raw, tick_size);
```

**Correct (preserve raw precision):**

```rust
tick.price = raw;  // Preserve feed precision
```

**Where to round:**
- Order submission (OrderRequest to broker API)
- Display formatting

**Where NOT to round:**
- Market data ingestion (preserve feed precision)
- P&L calculations (use raw values)

#### Display Formatting via Symbol Metadata

Format prices using the symbol's `display_decimals`, never hardcoded decimal places. Different instruments have different display precision (e.g., EURUSD: 5, AAPL: 2, BTC: 8).

**Incorrect (hardcoded decimals):**

```rust
format!("{:.2}", price)
```

**Correct (symbol-driven precision):**

```rust
format!("{:.1$}", price, symbol.display_decimals as usize)
```

### Type Design

How to structure price-related types -- newtypes, symbol metadata, display precision.

#### Symbol Metadata Owns Precision

Tick size and display precision belong in a per-symbol metadata struct, not in the price value itself.

**Incorrect (precision embedded in price):**

```rust
struct Price { value: f64, decimals: u8 }
```

**Correct (precision in symbol spec):**

```rust
#[derive(Clone, Copy)]
pub struct SymbolSpec {
    pub symbol_id: u32,
    pub tick_size: f64,         // Minimum price increment
    pub display_decimals: u8,   // Decimal places for UI
    pub lot_size: f64,          // Minimum quantity
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

Symbol table characteristics:
- Loaded at subscription setup (cold path)
- Keyed by symbol ID for O(1) lookup
- Re-synced on reconnect or symbol list change

#### Price Newtype Pattern

For additional type safety, wrap f64 in a zero-overhead newtype. Intentionally omit `PartialEq` to force explicit epsilon comparison.

```rust
#[derive(Clone, Copy, Debug, PartialOrd)]
#[repr(transparent)]  // Zero-overhead newtype
pub struct Price(f64);

impl Price {
    pub const ZERO: Price = Price(0.0);

    pub fn new(value: f64) -> Self {
        debug_assert!(value.is_finite(), "Price must be finite");
        Price(value)
    }

    pub fn raw(self) -> f64 { self.0 }

    pub fn approx_eq(self, other: Price) -> bool {
        prices_equal(self.0, other.0)
    }
}

// Intentionally NO PartialEq impl -- forces explicit comparison
```

**Trade-off**: Adds friction but prevents accidental `==` usage. Consider for order types; skip for market data hot path where the overhead of wrapping/unwrapping adds noise.

### Feed Ingestion

Patterns for normalizing price data from different feed formats (doubles, strings, scaled integers) to f64 at ingest without precision loss.

#### Normalize to f64 at Ingest

Convert all feed data to f64 at the ingest boundary. Different feeds use different wire formats; normalize once at entry.

```rust
// Feeds sending doubles (IB, dxFeed, Rithmic): pass through
fn ingest_double(value: f64) -> f64 { value }

// Feeds sending strings (Binance, Coinbase): parse
fn ingest_string(s: &str) -> Result<f64, ParseFloatError> {
    s.parse()
}

// Feeds sending scaled integers (CME MDP): unscale
fn ingest_scaled(mantissa: i64, exponent: i8) -> f64 {
    mantissa as f64 * 10f64.powi(exponent as i32)
}
```

After normalization, all downstream code works with plain `f64` regardless of feed source.
