# KEN-2416 refresh runs: gentoo-overlay

gentoo-overlay has 1 failed runs out of 1 listed runs in the fixed interval.

## Scope and counts

- [Measurement index](ken-2416-refresh-runs.md) owns the interval, inventory, denominators and code definitions.
- Repository: `vanillagreencom/gentoo-overlay`.
- Created-at interval, inclusive UTC: `2026-09-24T14:14:50Z` through `2026-10-01T14:14:50Z`.
- Retained created-at bounds: `2026-09-27T21:20:53Z` through `2026-09-27T21:20:53Z`.
- Listing: `tmp/ken-2416-gentoo-overlay-runs.json`.
- Counts: listed 1; completed 1; failure 1; success 0; cancelled 0; pending 0.
- Listed failure rate: 100.00%. Completed failure rate: 100.00%.

## Failure classes

| Cause class | Count |
| --- | ---: |
| `consumer-bootstrap` | 1 |

## Raw rows

Created cells are full UTC timestamps. Each URL preserves the run ID. Event, outcome, cause and evidence codes use the index definitions. Each row preserves the original observed outcome.

- Evidence F: `tmp/ken-2416-gentoo-overlay-RUN_ID.log`, with `.err` and `.exit` companions.
- Evidence L: the listing above. The listing and `tmp/ken-2416-classified-runs.json` retain attempt, branch, head SHA, update time and title.

| Created UTC | Run URL | Event | Outcome | Cause | Evidence |
| --- | --- | --- | --- | --- | --- |
| 2026-09-27T21:20:53Z | [run](https://github.com/vanillagreencom/gentoo-overlay/actions/runs/36351390143) | M | F | B | F |
