# Price Handling Patterns

Price-handling patterns for agents working on trading software. The skill covers comparisons, rounding, formatting, parsing and price types.

## Features

- Choose a price representation for the application.
- Compare prices with a tolerance.
- Round and format prices using symbol metadata.
- Normalize incoming feed values and wrap prices in dedicated types.

## Install

```bash
kendex add vanillagreencom/kendex --skill price-handling
```

## How it works

The agent loads [SKILL.md](SKILL.md) when it changes price handling. It identifies the incoming value, the required calculation and the output format. It uses the relevant pattern with the application's symbol metadata.

## Setup

Nothing to configure.

## Licence

MIT, in the repository's LICENSE file.
