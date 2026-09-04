# Price Handling Patterns

A reference skill for `f64` prices in a trading system: comparing, rounding to tick size, formatting for display and broker APIs, parsing market feeds, and designing price types. For a project whose agents touch prices and must not reach for `==`, ad-hoc rounding, or a decimal type by reflex.

## Install

```bash
kendex add vanillagreencom/kendex --skill price-handling
```

## What it does

- States when `f64` is the price type and the narrow cases that justify `i64` fixed-point.
- Gives the epsilon comparison helpers and the rule to never compare prices with `==`.
- Places rounding at the boundaries only, with symbol metadata owning precision.
- Shows a price newtype and how feeds are normalized to `f64` at ingest.

## How it works

An agent loads [SKILL.md](SKILL.md) when it compares, rounds, formats or parses a price, or designs a price type, and follows the patterns there.

## Customise

Nothing to configure.
