# Recorded GraphQL replies

One file per read verb and spelling. `recorded_read_case` in `../../assert.sh` replays them through the `live-resource-pages-replay-*.test.sh` suites.

Each file's replies came from running its `args` through `linear.sh` with the kendex application token, read-only, on 2026-10-04.

No script records the replies. A re-record captures each GraphQL reply the `args` run receives, in order, with its operation name, then replaces values as the list below sets out.

Every value that names something is a fixture value:

- Issue identifiers are `KEN-9NNN`.
- Ids are `00000000-0000-4000-8000-NNNNNNNNNNNN`.
- Team keys are `KEN`, or `FX` and a letter.
- Project, milestone, label, team and user names are `Fixture ...` values. A real name is kept only where the code reads the name itself: workflow states, the `research` and `agent:` labels, the `kendex` team.
- Text, emails, URLs and branch names are fixture text.

Keys, types, enums, nesting, nulls, ordering, page shape and the references between rows are as Linear answered. Request variables and headers are not kept. `recorded_fixture_values` in the assertion library refuses a fixture holding any other identifier, id, team key or name.

| Field | Meaning |
|---|---|
| `args` | The `linear.sh` arguments the replies answer |
| `requests` | The replies in the order the command asked for them, each with its operation name |
| `root_index` | The reply the replay splits into two cursor pages |
| `root_path` | The connection in that reply the replay splits |
| `output` | The jq path to that connection's rows in the command's output |
| `expected_rows` | How many rows a complete read prints |
| `output_lines` | The exact stdout lines a complete read prints, for a line format such as `--format=ids` |
| `derived_rows` | Present where the replay needed rows the workspace did not hold; says what was added |
| `provenance` | How the replies were recorded and what was replaced |

`output_lines` stands in place of `output` and `expected_rows`.

Initiatives are derived, as their `provenance` says: the application token has no `initiative:read` scope, so their rows carry exactly the fields the command's query selects.
