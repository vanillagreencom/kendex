# linear skill development

Maintainer notes. Consumer docs: [README.md](README.md); the agent command reference: [SKILL.md](SKILL.md).

## Adding a resource

1. Create `scripts/commands/<resource>.sh`, sourcing `../lib/common.sh` (auth, the GraphQL wire, resolvers, argument guards).
2. Add a `show_help()` and register the resource in `scripts/linear.sh`.
3. Register write actions that need a configured team with `linear_guard_write_action` (below), and guard a verb that creates an issue, changes an existing issue's fields, archives it or trashes it with the cross-team guard (below).
4. Update the Commands table in `SKILL.md`.

The GraphQL transport is `graphql_request` in `scripts/lib/common.sh`; cursor traversal and nested completion are `scripts/lib/pages.sh` (`graphql_pages` for a root collection, `graphql_query` for one entity or a mutation reply); output formats are `scripts/lib/formatters.sh`, which also holds the jq definitions those filters prepend (`ISSUE_RELATION_JQ` for issue relations, `PROJECT_PICK_JQ` for the rule deciding which project a name means); issue rules at create and transition time are `scripts/lib/issue-validation.sh`; the Bash 4 runtime preflight is `scripts/lib/bash-version.sh`.

## Team targeting

A team name is not a workspace-independent identifier: it resolves inside whatever workspace `LINEAR_API_KEY` reaches, so a substituted default writes into whichever tracker the key owns. Nothing here invents one.

`common.sh` resolves the target once per invocation:

- `DEFAULT_TEAM` is `LINEAR_TEAM` verbatim, empty when unset.
- `LINEAR_TEAM_TARGET` starts at `DEFAULT_TEAM`; `linear_set_team_target "$team"` registers an explicit `--team` over it. It must run in the command's own shell (not `$(...)`) so the value reaches the guards.
- `LINEAR_TEAM_SOURCE` / `LINEAR_API_KEY_SOURCE` record `environment`, `project-config`, or `unset`, captured before project files load.
- `LINEAR_TEAM_ENV_BLANK` marks the case the source values cannot express: `LINEAR_TEAM` exported empty. The parent-env snapshot in `kendex-env.sh` gives the process environment precedence over project files, so an empty export blocks a configured team while resolving to no target. It reports `team_source: "unset"` with `team_source_file: null` and warns that the export is shadowing the project value.

The dispatcher enforces the configured-team requirement for writes that do not address an issue. `linear_guard_write_action "$action" "<write actions>" "$@"` runs right after the action is parsed, before any API call. It reads only the first remaining argument, and only to let `<action> --help` through. It must never search argv for `--team`: that token can be free text in a body or title. The list holds writes that need a configured team and have no `--team` parser. The create actions that parse `--team` instead call `linear_set_team_target` and `linear_require_team_target` immediately after their parse loop. Existing-issue writes and `comments create` use the issue identifier. The GraphQL wire does not require a configured team.

Read paths omit the team filter when the target is empty; they never send an empty or guessed team name. `statuses` and `cycles` reads apply `LINEAR_TEAM` as their default filter; `issues list` filters by team only when `--team` is passed, and that asymmetry is load-bearing for cross-team listings.

The guard proves a team is configured, not that a write lands in it. A mutation addressed by an existing entity ID or identifier routes by that ID inside the workspace the key reaches. Issue writes resolve states and labels under the issue's own team. Newly created team-scoped entities land in the named team.

### Cross-team guard

Linear lets the fleet's one app token write in every team, whatever team access the app's settings name, so `common.sh` keeps issue writes in `LINEAR_TEAM`. `linear_guard_issue_team ACTION REF...` runs in each existing-issue verb that changes state, assignee, priority, labels, project or cycle, or archives or trashes the issue, before any write: `update_issue`, `activate_issue`, `block_issue`, `unblock_issue`, `complete_issue`, `archive_issue`, `trash_issue`, and `bulk_update_issues` for every identifier it collected. `linear_guard_create_team` runs in `create_issue` before any write. Reads, `comments create` and relations never call either.

- `LINEAR_TEAM_PASSED` holds the references the guard let through in this invocation, so `update_issue` called by another verb, in a subshell that inherits it, sends no second read and prints no second inactive line.
- An identifier's team is its prefix, upper-cased. Any other reference, a UUID, is read for `issue.team.key`; a failed read refuses as `refused=cross-team-unread`.
- A prefix equal to `LINEAR_TEAM` passes with no request. Otherwise `linear_own_team` resolves `LINEAR_TEAM` once per invocation through `resolve_team_node`, since the setting may name the team rather than key it, and the prefix must equal that key. A create compares team ids.
- The refusal is the keyed `linear: refused=cross-team ... route=peer-mail` line, then a `fix=` line naming `lane-mail peer send --repo`. With no `LINEAR_TEAM`, both guards print `linear: cross-team-guard=inactive action=<verb> cause=no-team` and let the write through.
- An identifier moved to another team keeps resolving in Linear under its old prefix; the guard judges the prefix it was given.

`kendex.settings.toml.example` marks `LINEAR_TEAM` `# required`, so a project gets the key and its comment when this skill arrives, and the arrival writes no other key in that file; what an arrival writes, and when, is kendex's `docs/authoring/settings.md`. The written `LINEAR_TEAM = ""` is inert: empty is exactly the unset case, so an unedited seed keeps writes that need a configured team refused.

## Authoring rules

- `scripts/commands/issues.sh`'s `get_issue` owns live issue validation. A successful read carries a nonempty canonical ID before callers upload existing-issue attachments. `tests/issues-update-attach.test.sh` and `tests/comments-create-attach.test.sh` exercise that order.
- Resource help and a default-help command's bare form return before `common.sh` loads project configuration. Nested help stays with the command parser that owns its option arity.
- Build every GraphQL variables payload with `jq --arg` / `--argjson`. A name holding a quote must not be able to reshape the request, and a hand-built payload fails as "Invalid GraphQL variables JSON", which names neither the flag nor the value.
- Validate any value spliced unquoted into JSON, a jq program, or shell arithmetic with `linear_require_pattern` before it gets there.
- Read a root collection through `graphql_pages`, and request `pageInfo { hasNextPage endCursor }` and `$after` in its query. A list verb reads through `linear_list_read` instead, after `linear_list_reset`, handing `--limit`, `--max` and `--first` to `linear_list_option`: `lib/pages.sh` owns the default bound, the page size and the truncation notice, and `linear_list_page_size` reads the page from the query itself, smaller where the rows select a connection. A bulk read of named issues goes through `linear_issue_refs_read`, which owns the batch read, the lookup of a reference it left unanswered and the `missing` refusal. Every nested connection a `graphql_query` or `graphql_pages` read selects carries `pageInfo` too: `lib/pages.sh` completes an open one with the fields `linear_connection_fields` lists for it, and refuses a connection that does not say whether it is open. A new nested connection therefore adds its row there, with the fields its query selects. A connection bounded on purpose, such as `projects list-updates`' ten most recent updates, reads through `graphql_request`, which completes nothing.
- Pass response-sized JSON to jq on standard input, never through `--argjson` or `--arg`: one argument is capped at 128 KiB on Linux, and a large page or issue description crosses it.
- Distinguish "the lookup failed" from "there is no such thing". `resolve_label_id` returns 2 for the former and 1 for the latter precisely because `--labels` replaces a label set, where the two outcomes differ by data loss.
- Build any timestamp compared against Linear's `startsAt` or `updatedAt`, here or in a server-side date filter, with `linear_now_utc` or `linear_utc_days_ago` from `scripts/lib/cycle-dates.sh`, never `date -Iseconds`. The comparison is lexical against Linear's UTC strings, so a local-time value with an offset suffix only agrees on a UTC host.
- Select a cycle by date, not by position in the sorted set. `linear_working_cycle`, `linear_cycles_before` and `linear_cycles_after` are the definitions, and every caller hands the working cycle over unguarded: with none running they cut at today.

## Tests

```bash
for t in skills/linear/tests/*.test.sh; do bash "$t" || echo "FAIL $t"; done
skills/linear/tests/must-fail-controls.sh
```

Each test stands up its own fixture root and a `curl` shim on `PATH`, so none reaches the network. `LINEAR_API_KEY_OVERRIDE` is the inline auth channel they use. A suite that changes an existing issue sets `LINEAR_TEAM` to that issue's prefix, or the cross-team guard refuses the write or sends a team lookup the shim does not expect; a suite that sources `issues.sh` without the shim sets it too, since the checkout's own `LINEAR_TEAM` would otherwise send that lookup to Linear.

`tests/issues-activate-agent.test.sh` and `tests/issues-update-unknown-label-refuses.test.sh` use projected live Linear responses in `tests/lib/fixtures/` for cross-team labels. The curl fixture applies the request's team filter to the recorded duplicate names. Their controls remove the scope or the refusal, so either error must turn the suite red.

`tests/oauth-auth.test.sh` distinguishes the selected credential from unused key provenance in credential reports. `tests/api-key-precedence.test.sh` and `tests/team-target-fail-closed.test.sh` cover personal-key and team warnings.

The `tests/live-resource-pages-replay-*.test.sh` suites drive each read verb through `linear.sh` against the GraphQL replies in `tests/lib/fixtures/recorded/`, recorded from Linear or derived in their shape where the token cannot read, through `recorded_read_case` in the assertion library, which also refuses a fixture holding anything but fixture values (the fixtures' README): the complete chain returns every row, and a later page that fails leaves stdout empty. A new read verb adds a recorded fixture and a row in one of those suites. `PROJECT_ROOT` is not a redirect and cannot be made one: `common.sh` assigns it from `git rev-parse` on every source, so a value you export never survives to be read.

### Assertions

Every claim goes through `tests/lib/assert.sh`, which counts assertions and fails a suite that reaches its end without executing one: an exit code reports on the process, not on anything that was checked. Sourcing the library installs that verdict as an EXIT trap, so scratch directories come from `assert_tmpdir` and teardown from `assert_at_exit`; another `trap ... EXIT` replaces the verdict and disarms it. Helpers record a failure and return, so one run reports every failure.

An assertion made in a subshell (a command substitution, a pipeline element, a backgrounded or parenthesised block) increments a counter the suite never sees, so the library refuses the shape. A subshell that finished is caught by the count: every assertion also appends to a ledger file a subshell shares with its parent, and a disagreement with the in-memory counter fails the suite naming how many were lost. A background job still running at the verdict is caught by its presence, because its record would land after the totals are computed; the verdict refuses an outstanding job rather than waiting for it, since a suite that never returns is worse than one that refuses. Capture the status in the suite and assert on it there.

`set -e` is suspended for the whole body of a command whose status is being tested (an `if` condition, a `&&`/`||` operand, a `!`), and that suspension reaches into a shell function called there and every function it calls, so capture the subject's status instead of branching on it: `rc=0; cmd || rc=$?` where the subject is its own process and carries its own errexit, and `run_status rc func` / `run_output out rc func` where it is a shell function, which run it in a background subshell whose errexit was never suspended. `run_status` refuses a call site where errexit is not in force rather than reporting a status it cannot stand behind; `tests/run-status-errexit.test.sh` pins both the property and that refusal.

### Must-fail controls

`tests/controls/<suite>.control.sh` breaks the one behaviour its suite covers, in a copy of the skill, and `tests/must-fail-controls.sh` requires the suite to go red naming the assertion that covers it. A suite with no control fails the run: an untested control is an untested suite. So does a control no suite owns, reported as `ORPHAN`. The roster is read in both directions whatever the selection, so a single-stem run cannot pass while a control sits in the directory unrun.

A control declares what it expects with `control_expect <assertion description>` and mutates with `control_replace <file> <count> <old line> <new line>`, whole-line and literal, so there is no pattern syntax to mis-escape. `control_replace` aborts unless it matches exactly `count` lines, and the runner refuses a control that changed nothing, so a mutation that failed to land can never be read as a passing control. It also refuses a stem that names no suite and a selection that matched none, because a run that measured nothing is not a run that passed.

Every mutation a control declares is staged and run on its own copy of the skill, and names the assertion it must redden. The name is matched whole against one line of the suite's output, so it is the assertion's full description and not a prefix of it. Every declared assertion belongs to exactly one mutation, the one declared after it, and that mutation's own run must redden it. The verdicts: `WRONG` names a mutation whose run did not redden its assertion, which is what refuses one reddening only a harness verdict from `tests/lib/assert.sh`, since those carry the same `FAIL:` prefix an assertion does; `SHARED` names two mutations claiming one assertion; `NOEXPECT` a mutation claiming none; `GREEN` a mutation the suite survived; `TIMEOUT` one the suite timeout killed; `UNGATED` a control that edited its copy outside `control_replace`, `control_append` or `control_write`, since only those are numbered. `UNGATED` compares the copy after the counting pass, so it refuses an unconditional edit and not one made only while a mutation is applied. Write every edit through the three helpers. A mutation that stops `graphql_pages` before a connection's last page while that connection still reads open recurses through `linear_complete_entity` until the suite timeout, and reports `TIMEOUT`: drop the rows read instead. Because each mutation lands on a copy no other mutation has touched, write every one against the file as it ships: a mutation that only matches a line another mutation leaves behind aborts the control, and two mutations may target the same line. `tests/mutation-isolation.test.sh` pins each verdict.

The runner copies the linear skill alone, so a suite that also runs another skill's script cannot live here. It lives in that skill's `tests/` and skips under Bash 3, the shell the macOS leg runs other skills' suites in: `skills/orch/tests/reconcile-work-items-complete.test.sh`.
