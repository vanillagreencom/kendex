# linear skill development

Maintainer notes. Consumer docs: [README.md](README.md); the agent command reference: [SKILL.md](SKILL.md).

## Adding a resource

1. Create `scripts/commands/<resource>.sh`, sourcing `../lib/common.sh` (auth, the GraphQL wire, resolvers, argument guards).
2. Add a `show_help()` and register the resource in `scripts/linear.sh`.
3. Register write actions that need a configured team with `linear_guard_write_action` in `scripts/lib/common.sh`.
4. Guard a verb that creates an issue, changes an existing issue's fields, archives it or trashes it with the cross-team guard: `linear_guard_create_team` or `linear_guard_issue_team` in `scripts/lib/common.sh`.
5. Update the Commands table in `SKILL.md`.

Where each job lives:

- The GraphQL transport is `graphql_request` in `scripts/lib/common.sh`.
- Cursor traversal and nested completion are `scripts/lib/pages.sh`: `graphql_pages` for a root collection, `graphql_query` for one entity or a mutation reply.
- Output formats are `scripts/lib/formatters.sh`. It also holds the jq definitions those filters prepend: `ISSUE_RELATION_JQ` for issue relations, `PROJECT_PICK_JQ` for the rule deciding which project a name means.
- Issue rules at create and transition time are `scripts/lib/issue-validation.sh`.
- The Bash 4 runtime preflight is `scripts/lib/bash-version.sh`.

## Team targeting

`scripts/lib/common.sh` § Team targeting and § Cross-team guard state the rules at the code.

- `linear_set_team_target "$team"` registers an explicit `--team` over `LINEAR_TEAM`. Call it in the command's own shell, not `$(...)`, so the value reaches the guards.
- `statuses` and `cycles` reads apply `LINEAR_TEAM` as their default filter. `issues list` filters by team only when `--team` is passed. That asymmetry is load-bearing for cross-team listings.

## Authoring rules

- `scripts/commands/issues.sh`'s `get_issue` owns live issue validation. A successful read carries a nonempty canonical ID before callers upload existing-issue attachments. `tests/issues-update-attach.test.sh` and `tests/comments-create-attach.test.sh` exercise that order.
- Resource help and a default-help command's bare form return before `common.sh` loads project configuration. Nested help stays with the command parser that owns its option arity.
- Build every GraphQL variables payload with `jq --arg` / `--argjson`. A name holding a quote must not be able to reshape the request, and a hand-built payload fails as "Invalid GraphQL variables JSON", which names neither the flag nor the value.
- Validate any value spliced unquoted into JSON, a jq program, or shell arithmetic with `linear_require_pattern` before it gets there.
- Read a root collection through `graphql_pages`, and request `pageInfo { hasNextPage endCursor }` and `$after` in its query.
  - A list verb reads through `linear_list_read` instead, after `linear_list_reset`, handing `--limit`, `--max` and `--first` to `linear_list_option`.
  - `lib/pages.sh` owns the default bound, the page size and the truncation notice. `linear_list_page_size` reads the page from the query itself, smaller where the rows select a connection.
  - A bulk read of named issues goes through `linear_issue_refs_read`, which owns the batch read, the lookup of a reference it left unanswered and the `missing` refusal.
  - Every nested connection a `graphql_query` or `graphql_pages` read selects carries `pageInfo` too. `lib/pages.sh` completes an open one with the fields `linear_connection_fields` lists for it, and refuses a connection that does not say whether it is open.
  - A new nested connection therefore adds its row in `linear_connection_fields`, with the fields its query selects.
  - A connection bounded on purpose, such as `projects list-updates`' ten most recent updates, reads through `graphql_request`, which completes nothing.
- Open every GraphQL document with its operation keyword. `graphql_request` sends a document that opens with `query` again after a 5xx or no answer. It sends any other document once on those answers, since a mutation Linear applied before the answer was lost would be applied twice.
- Pass response-sized JSON to jq on standard input, never through `--argjson` or `--arg`: one argument is capped at 128 KiB on Linux, and a large page or issue description crosses it.
- Distinguish "the lookup failed" from "there is no such thing". `resolve_label_id` returns 2 for the former and 1 for the latter precisely because `--labels` replaces a label set, where the two outcomes differ by data loss.
- Build any timestamp compared against Linear's `startsAt` or `updatedAt`, here or in a server-side date filter, with `linear_now_utc` or `linear_utc_days_ago` from `scripts/lib/cycle-dates.sh`. Never use `date -Iseconds`: the comparison is lexical against Linear's UTC strings, so a local-time value with an offset suffix only agrees on a UTC host.
- Select a cycle by date, not by position in the sorted set or by its progress. A cycle runs from its `startsAt` until its `endsAt`.
  - `linear_working_cycle`, `linear_cycles_before` and `linear_cycles_after` are the definitions.
  - Every caller hands the working cycle over unguarded. With none running, they cut at today.

## Tests

```bash
for t in skills/linear/tests/*.test.sh; do bash "$t" || echo "FAIL $t"; done
skills/linear/tests/must-fail-controls.sh
```

Each test stands up its own fixture root and a `curl` shim on `PATH`, so none reaches the network. `LINEAR_API_KEY_OVERRIDE` is the inline auth channel they use.

- A suite that changes an existing issue sets `LINEAR_TEAM` to that issue's prefix. Otherwise the cross-team guard refuses the write or sends a team lookup the shim does not expect.
- A suite that sources `issues.sh` without the shim sets it too, since the checkout's own `LINEAR_TEAM` would otherwise send that lookup to Linear.

The `tests/live-resource-pages-replay-*.test.sh` suites drive each read verb through `linear.sh` against the GraphQL replies in `tests/lib/fixtures/recorded/`, through `recorded_read_case` in the assertion library. The fixtures' README says how the replies were recorded.

- A new read verb adds a recorded fixture and a row in one of those suites.
- `PROJECT_ROOT` is not a redirect and cannot be made one: `common.sh` assigns it from `git rev-parse` on every source, so a value you export never survives to be read.

### Assertions

Every claim goes through `tests/lib/assert.sh`, which counts assertions and fails a suite that reaches its end without executing one.

- Sourcing the library installs that verdict as an EXIT trap.
- Scratch directories come from `assert_tmpdir`, and teardown from `assert_at_exit`.
- Another `trap ... EXIT` replaces the verdict and disarms it.
- Helpers record a failure and return, so one run reports every failure.

An assertion made in a subshell (a command substitution, a pipeline element, a backgrounded or parenthesised block) increments a counter the suite never sees, so the library refuses the shape. Capture the status in the suite and assert on it there.

`set -e` is suspended for the whole body of a command whose status is being tested: an `if` condition, a `&&`/`||` operand, a `!`. That suspension reaches into a shell function called there and every function it calls. So capture the subject's status instead of branching on it:

- `rc=0; cmd || rc=$?` where the subject is its own process and carries its own errexit.
- `run_status rc func` / `run_output out rc func` where it is a shell function. They run it in a background subshell whose errexit was never suspended.

### Must-fail controls

`tests/controls/<suite>.control.sh` breaks the one behaviour its suite covers, in a copy of the skill. `tests/must-fail-controls.sh` requires the suite to go red naming the assertion that covers it.

- A suite with no control fails the run.
- So does a control no suite owns, reported as `ORPHAN`.
- The roster is read in both directions whatever the selection.

A control declares what it expects with `control_expect <assertion description>`. It mutates with `control_replace <file> <count> <old line> <new line>`, whole-line and literal.

- `control_replace` aborts unless it matches exactly `count` lines.
- The runner refuses a control that changed nothing.
- It also refuses a stem that names no suite and a selection that matched none.

Every mutation a control declares is staged and run on its own copy of the skill, and names the assertion it must redden.

- The name is matched whole against one line of the suite's output, so it is the assertion's full description and not a prefix of it.
- Every declared assertion belongs to exactly one mutation, the one declared after it, and that mutation's own run must redden it.

The verdicts:

- `WRONG`: a mutation whose run did not redden its assertion. It also refuses one reddening only a harness verdict from `tests/lib/assert.sh`, since those carry the same `FAIL:` prefix an assertion does.
- `SHARED`: two mutations claiming one assertion.
- `NOEXPECT`: a mutation claiming none.
- `GREEN`: a mutation the suite survived.
- `TIMEOUT`: a mutation the suite timeout killed.
- `UNGATED`: a control that edited its copy outside `control_replace`, `control_append` or `control_write`, since only those are numbered. It compares the copy after the counting pass, so it refuses an unconditional edit and not one made only while a mutation is applied.

Write each mutation this way:

- Write every edit through the three helpers.
- A mutation that stops `graphql_pages` before a connection's last page while that connection still reads open recurses through `linear_complete_entity` until the suite timeout, and reports `TIMEOUT`. Drop the rows read instead.
- Write every mutation against the file as it ships: each mutation lands on a copy no other mutation has touched. A mutation that only matches a line another mutation leaves behind aborts the control, and two mutations may target the same line.

A control proves its suite's instrument once, so it declares one mutation, not one per row. A second mutation stands only where the suite holds a second instrument the first cannot redden, with a comment naming the failure that instrument guards: `controls/mutation-isolation.control.sh` (the suite cap) and `controls/oauth-auth.control.sh` (the token store).

The runner copies the linear skill alone, so a suite that also runs another skill's script cannot live here. It lives in that skill's `tests/` and skips under Bash 3, the shell the macOS leg runs other skills' suites in.
