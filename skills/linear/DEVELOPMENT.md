# linear skill development

## Structure

```
skills/linear/
├── SKILL.md                    # Agent-facing command reference
├── scripts/
│   ├── linear.sh               # Entry point (resource router)
│   ├── commands/               # One script per resource
│   └── lib/
│       ├── bash-version.sh     # Bash 4+ runtime preflight
│       ├── common.sh           # Auth, GraphQL wire, resolvers, arg guards
│       ├── cache.sh            # Cache reads, merges, write-through
│       ├── formatters.sh       # safe / table / ids / raw output
│       ├── attachments.sh      # Attachment upload and download
│       └── issue-validation.sh # Completion-role state rules
└── patterns/workflow-actions.md
```

## Adding a Resource

1. Create `scripts/commands/<resource>.sh`, sourcing `../lib/common.sh`.
2. Add a `show_help()` and register the resource in `scripts/linear.sh`.
3. Register its write actions with `linear_guard_write_action` (below).
4. Update the Commands table in `SKILL.md`.

## Team Targeting

A team name is not a workspace-independent identifier: it resolves inside whatever workspace `LINEAR_API_KEY` reaches, so a substituted default writes into whichever tracker the key owns. Nothing here invents one.

`common.sh` resolves the target once per invocation:

- `DEFAULT_TEAM` is `LINEAR_TEAM` verbatim, empty when unset.
- `LINEAR_TEAM_TARGET` starts at `DEFAULT_TEAM`; `linear_set_team_target "$team"` registers an explicit `--team` over it. It must run in the command's own shell (not `$(...)`) so the value reaches the guards.
- `LINEAR_TEAM_SOURCE` / `LINEAR_API_KEY_SOURCE` record `environment`, `project-config`, or `unset`, captured before project files load.
- `LINEAR_TEAM_ENV_BLANK` marks the case the source values cannot express: `LINEAR_TEAM` exported empty. The parent-env snapshot in `vstack-env.sh` gives the process environment precedence over project files, so an empty export blocks a configured team while resolving to no target. It reports `team_source: "unset"` with `team_source_file: null` and warns that the export is shadowing the project value.

Two layers enforce the fail-closed rule:

1. **Dispatcher** — `linear_guard_write_action "$action" "<write actions>" "$@"` runs right after the action is parsed, so a write refuses before any API call, including identifier lookups. It reads only the first remaining argument, and only to let `<action> --help` through. It must never search argv for `--team`: that token is as likely to be free text in a comment body or issue title, and honoring it would let user content open the gate. The list holds the write actions with **no** `--team` parser. The four that do parse one — `issues create`, `projects create`, `cycles create`, `labels create` — are omitted and instead call `linear_set_team_target` + `linear_require_team_target` immediately after their parse loop. Adding `--team` to another write means moving it out of the dispatcher list and into that pattern.
2. **Wire** — `graphql_query` refuses any document whose first token is `mutation` when `LINEAR_TEAM_TARGET` is empty, so an action missing from a dispatcher list degrades to a later refusal, never to a cross-workspace write. `linear_query_is_mutation` classifies by the leading token, so a document burying its operation behind a leading fragment would evade it; `tests/graphql-document-classification.test.sh` fails the build if any document in `scripts/` takes that shape.

Read paths omit the team filter when the target is empty; they never send an empty or guessed team name. `statuses` and `cycles` reads apply `LINEAR_TEAM` as their default filter; `issues list` filters by team only when `--team` is passed, and that asymmetry is load-bearing for cross-team listings.

### What the Guard Does Not Cover

The guard proves a team is **configured**, not that a write lands in it. A mutation addressed by an existing entity ID or identifier (`issues update ABC-123`, `comments create`, relation and project mutations) is routed by that ID inside whatever workspace the key reaches. With `LINEAR_TEAM` set to one team, `issues update <id-from-another-workspace>` still succeeds. So the guarantee is: an unconfigured project cannot write to Linear at all, and newly created entities land in the named team. Validating that an identifier belongs to `LINEAR_TEAM` would cost a lookup on every mutation and is not implemented.

Projects are seeded with `vstack.settings.toml.example`, which `vstack add` / `vstack refresh` merge without overwriting existing keys. The seeded `LINEAR_TEAM = ""` is inert: empty is exactly the unset case, so an unedited seed keeps writes refused.

## Authoring Rules

- Build every GraphQL variables payload with `jq --arg` / `--argjson`. A name holding a quote must not be able to reshape the request, and a hand-built payload fails as "Invalid GraphQL variables JSON", which names neither the flag nor the value.
- Validate any value spliced unquoted into JSON, a jq program, or shell arithmetic with `linear_require_pattern` before it gets there.
- Read cache files through `cache_jq_file`. An absent file is a cold cache and returns the caller's default; a file that exists but does not parse must fail loudly, because the same empty default would report a corrupt cache as "no results".
- Distinguish "the lookup failed" from "there is no such thing". `resolve_label_id` returns 2 for the former and 1 for the latter precisely because `--labels` replaces a label set, where the two outcomes differ by data loss.

## Tests

```bash
for t in skills/linear/tests/*.test.sh; do bash "$t" || echo "FAIL $t"; done
```

Each test stands up its own fixture root and a `curl` shim on `PATH`, so none reaches the network. `LINEAR_API_KEY_OVERRIDE` is the inline auth channel they use; `cache.sh` refuses to write when that override is paired with a cache dir inside a real checkout, so a test that forgets to isolate `PROJECT_ROOT` fails instead of polluting live cache data.
