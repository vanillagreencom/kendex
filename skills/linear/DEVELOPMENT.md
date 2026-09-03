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
│       └── issue-validation.sh # Issue rules at create and transition time
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
- `LINEAR_TEAM_ENV_BLANK` marks the case the source values cannot express: `LINEAR_TEAM` exported empty. The parent-env snapshot in `kendex-env.sh` gives the process environment precedence over project files, so an empty export blocks a configured team while resolving to no target. It reports `team_source: "unset"` with `team_source_file: null` and warns that the export is shadowing the project value.

Two layers enforce the fail-closed rule:

1. **Dispatcher** — `linear_guard_write_action "$action" "<write actions>" "$@"` runs right after the action is parsed, so a write refuses before any API call, including identifier lookups. It reads only the first remaining argument, and only to let `<action> --help` through. It must never search argv for `--team`: that token is as likely to be free text in a comment body or issue title, and honoring it would let user content open the gate. The list holds the write actions with **no** `--team` parser. The four that do parse one — `issues create`, `projects create`, `cycles create`, `labels create` — are omitted and instead call `linear_set_team_target` + `linear_require_team_target` immediately after their parse loop. Adding `--team` to another write means moving it out of the dispatcher list and into that pattern.
2. **Wire** — `graphql_query` refuses any document whose first token is `mutation` when `LINEAR_TEAM_TARGET` is empty, so an action missing from a dispatcher list degrades to a later refusal, never to a cross-workspace write. `linear_query_is_mutation` classifies by the leading token, so a document burying its operation behind a leading fragment would evade it; `tests/graphql-document-classification.test.sh` fails the build if any document in `scripts/` takes that shape.

Read paths omit the team filter when the target is empty; they never send an empty or guessed team name. `statuses` and `cycles` reads apply `LINEAR_TEAM` as their default filter; `issues list` filters by team only when `--team` is passed, and that asymmetry is load-bearing for cross-team listings.

### What the Guard Does Not Cover

The guard proves a team is **configured**, not that a write lands in it. A mutation addressed by an existing entity ID or identifier (`issues update ABC-123`, `comments create`, relation and project mutations) is routed by that ID inside whatever workspace the key reaches. With `LINEAR_TEAM` set to one team, `issues update <id-from-another-workspace>` still succeeds. So the guarantee is: an unconfigured project cannot write to Linear at all, and newly created entities land in the named team. Validating that an identifier belongs to `LINEAR_TEAM` would cost a lookup on every mutation and is not implemented.

`kendex.settings.toml.example` marks `LINEAR_TEAM` `# required`, so a project gets the key and its comment when this skill arrives, and no other key in that file reaches their settings — what an arrival writes, and when, is kendex's docs/authoring/settings.md. The written `LINEAR_TEAM = ""` is inert: empty is exactly the unset case, so an unedited seed keeps writes refused.

## Authoring Rules

- Resource help and a default-help command's bare form return before
  `common.sh` loads project configuration. Nested help stays with the command
  parser that owns its option arity.
- Build every GraphQL variables payload with `jq --arg` / `--argjson`. A name holding a quote must not be able to reshape the request, and a hand-built payload fails as "Invalid GraphQL variables JSON", which names neither the flag nor the value.
- Validate any value spliced unquoted into JSON, a jq program, or shell arithmetic with `linear_require_pattern` before it gets there.
- Read cache files through `cache_jq_file`. An absent file is a cold cache and returns the caller's default; a file that exists but does not parse must fail loudly, because the same empty default would report a corrupt cache as "no results".
- Distinguish "the lookup failed" from "there is no such thing". `resolve_label_id` returns 2 for the former and 1 for the latter precisely because `--labels` replaces a label set, where the two outcomes differ by data loss.
- Build any timestamp compared against a cached `startsAt` or `updatedAt` with `cache_now_utc` or `cache_utc_days_ago` from `scripts/lib/cache-dates.sh`, never `date -Iseconds`. The comparison is lexical against records sync stores in UTC, so a local-time value with an offset suffix only agrees on a UTC host (KEN-1175). `date -Iseconds` is right for a timestamp this skill *writes*, such as `sync`'s `synced_at`.
- Select a cycle by date, not by position in the sorted set. `cache_working_cycle`, `cache_cycles_before` and `cache_cycles_after` are the definitions, and every caller hands the working cycle over unguarded: with none running they cut at today, where reading the ends of the list answered "previous" with a cycle that had not started. A caller that guards on `working == null` instead reintroduces the divergence — one cache answering `--type past` with a cycle and `--cycle previous` with a refusal.

## Tests

```bash
for t in skills/linear/tests/*.test.sh; do bash "$t" || echo "FAIL $t"; done
skills/linear/tests/must-fail-controls.sh
```

Each test stands up its own fixture root and a `curl` shim on `PATH`, so none reaches the network. `LINEAR_API_KEY_OVERRIDE` is the inline auth channel they use.

The cache is isolated for you. Sourcing `tests/lib/assert.sh` exports `LINEAR_CACHE_ROOT` at a scratch root that goes with the suite's other scratch directories at exit, and the scripts check that variable before anything derived from where the process is standing — so a suite that asks for nothing writes nowhere near the real `.cache/linear`. A suite that stands up its own project root points `LINEAR_CACHE_ROOT` at that root instead; one whose subject *is* the root resolution runs its invocations under `env -u LINEAR_CACHE_ROOT`. The verdict refuses a suite that ends with the variable unset or aimed outside the scratch it registered. `PROJECT_ROOT` is not a redirect and cannot be made one: `common.sh` assigns it from `git rev-parse` on every source, so a value you export never survives to be read.

### Assertions

Every claim goes through `tests/lib/assert.sh`, which counts assertions and fails a suite that reaches its end without executing one: an exit code reports on the process, not on anything that was checked. Sourcing the library installs that verdict as an EXIT trap, so scratch directories come from `assert_tmpdir` and teardown from `assert_at_exit` — another `trap ... EXIT` replaces the verdict and disarms it. Helpers record a failure and return, so one run reports every failure.

An assertion made in a subshell — a command substitution, a pipeline element, a backgrounded or parenthesised block — increments a counter the suite never sees and records a failure nobody reads, so the library refuses the shape rather than leaving authors to avoid it. Two things can go wrong and each has its own check: a subshell that finished is caught by the count, since every assertion also appends to a ledger file a subshell shares with its parent and a disagreement with the in-memory counter fails the suite naming how many were lost; a background job still running at the verdict is caught by its presence, because its record would land after the totals are computed and after the ledger is removed. The verdict refuses an outstanding job rather than waiting for it — waiting can hang forever on one that never exits, and a suite that never returns is worse than one that refuses. Capture the status in the suite and assert on it there.

`set -e` is suspended for the whole body of a command whose status is being tested — an `if` condition, a `&&`/`||` operand, a `!` — and that suspension reaches into a shell function called there and every function it calls, so capture the subject's status instead of branching on it: `rc=0; cmd || rc=$?` where the subject is its own process and carries its own errexit, and `run_status rc func` / `run_output out rc func` where it is a shell function, which run it in a background subshell whose errexit was never suspended.

The distinction is not a judgement call left to the author: `run_status` refuses a call site where errexit is not in force rather than reporting a status it cannot stand behind, and `tests/run-status-errexit.test.sh` pins both the property and that refusal.

### Must-fail controls

`tests/controls/<suite>.control.sh` breaks the one behaviour its suite covers, in a copy of the skill, and `tests/must-fail-controls.sh` requires the suite to go red naming the assertion that covers it. A suite with no control fails the run: an untested control is an untested suite. So does a control no suite owns, reported as `ORPHAN`: nothing runs it, so its mutation is never applied and the behaviour it names is unproven. The roster is read in both directions whatever the selection, so a single-stem run cannot pass while a control sits in the directory unrun.

A control declares what it expects with `control_expect <assertion description>` and mutates with `control_replace <file> <count> <old line> <new line>` — whole-line and literal, so there is no pattern syntax to mis-escape. `control_replace` aborts unless it matches exactly `count` lines, and the runner refuses a control that changed nothing, so a mutation that failed to land can never be read as a passing control. It also refuses a stem that names no suite and a selection that matched none, because a run that measured nothing is not a run that passed.

Every mutation a control declares is staged and run on its own copy of the skill, and names the assertion it must redden. The name is matched whole against one line of the suite's output, so it is the assertion's full description and not a prefix of it. Every declared assertion belongs to exactly one mutation — the one declared after it — and that mutation's own run must redden it. `WRONG` names a mutation whose run did not, which is what refuses one reddening only a harness verdict from `tests/lib/assert.sh`, since those carry the same `FAIL:` prefix an assertion does. `SHARED` names two mutations claiming one assertion, and `NOEXPECT` a mutation claiming none: the other two ways a mutation stops answering for itself. Alongside that rule the runner still reports the run a mutation never got: `GREEN` for a mutation the suite survived, `TIMEOUT` for one the suite timeout killed, and `UNGATED` for a control that edited its copy outside `control_replace`, `control_append` or `control_write`, since only those are numbered and an edit made any other way would ride the counting pass and every mutation pass uncounted. What `UNGATED` refuses is an unconditional edit: it compares the copy after the counting pass, so an edit a control makes only when a mutation is being applied leaves that pass clean and is not attributed to any helper. Write every edit through the three helpers. Because each mutation lands on a copy no other mutation has touched, write every one against the file as it ships — a mutation that only matches a line another mutation leaves behind aborts the control, and two mutations may target the same line. `tests/mutation-isolation.test.sh` pins each verdict.
