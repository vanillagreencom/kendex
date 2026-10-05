# Recorded GraphQL replies

One file per read verb and spelling. `recorded_read_case` in `../../assert.sh` replays them through the `live-resource-pages-replay-*.test.sh` suites.

Each file's replies came from running its `args` through `linear.sh` with the kendex application token, read-only, on 2026-10-04. Every value that names something is a fixture value: issue identifiers are `KEN-9NNN`, ids are `00000000-0000-4000-8000-NNNNNNNNNNNN`, team keys are `KEN` or `FX` and a letter, and project, milestone, label, team and user names are `Fixture ...` values, kept only where the code reads the name itself (workflow states, the `research` and `agent:` labels, the `kendex` team). Text, emails, URLs and branch names are fixture text. Keys, types, enums, nesting, nulls, ordering, page shape and the references between rows are as Linear answered. Request variables and headers are not kept. `recorded_fixture_values` in the assertion library refuses a fixture holding any other identifier, id, team key or name.

| Field | Meaning |
|---|---|
| `args` | The `linear.sh` arguments the replies answer |
| `requests` | The replies in the order the command asked for them, each with its operation name |
| `root_index`, `root_path` | The reply and the connection the replay splits into two cursor pages |
| `output`, `expected_rows` | The jq path to that connection's rows in the command's output, and how many a complete read prints |
| `output_lines` | In place of the two above, the exact stdout lines a complete read prints, for a line format such as `--format=ids` |
| `derived_rows` | Present where the replay needed rows the workspace did not hold; says what was added |
| `provenance` | How the replies were recorded and what was replaced |

Initiatives are derived, as their `provenance` says: the application token has no `initiative:read` scope, so their rows carry exactly the fields the command's query selects.
