# linear skill development

## Structure

```
skills/linear/
├── SKILL.md                    # Agent-facing skill definition
├── scripts/
│   ├── linear.sh               # Entry point (resource router)
│   ├── commands/               # Individual resource scripts
│   └── lib/
│       ├── bash-version.sh      # Bash 4+ runtime preflight
│       ├── common.sh           # Auth, GraphQL, formatting
│       ├── cache.sh            # Cache management
│       ├── formatters.sh       # Output formatters (safe, table, ids, raw)
│       ├── attachments.sh      # Attachment download and caching
│       └── issue-validation.sh # Issue state validation
└── patterns/
    └── workflow-actions.md     # Multi-step issue/project state transitions
```

## Adding a Resource

1. Create `scripts/commands/<resource>.sh`
2. Source `../lib/common.sh`
3. Add `show_help()` function
4. Add to case statement in `scripts/linear.sh`
5. Register the script's write actions with `linear_guard_write_action` (see below)
6. Update Commands table in `SKILL.md`

## Team Targeting

A team name is not a workspace-independent identifier: it resolves inside
whatever workspace `LINEAR_API_KEY` reaches. A substituted default therefore
writes into whichever tracker the key happens to own, so nothing in the skill
invents one.

`common.sh` resolves the target once per invocation:

- `DEFAULT_TEAM` is `LINEAR_TEAM` verbatim, empty when unset.
- `LINEAR_TEAM_TARGET` starts at `DEFAULT_TEAM`; `linear_set_team_target "$team"`
  registers an explicit `--team` over it. It must run in the command's own shell
  (not `$(...)`) so the value reaches the guards.
- `LINEAR_TEAM_SOURCE` / `LINEAR_API_KEY_SOURCE` record `environment`,
  `project-config`, or `unset`, captured before project files load. `auth-check`
  reports them and flags a machine-wide key paired with no project team.
- `LINEAR_TEAM_ENV_BLANK` marks the one case the source values cannot express:
  `LINEAR_TEAM` exported as an empty string. The parent-env snapshot in
  `vstack-env.sh` gives the process environment precedence over project files,
  so an empty export blocks a configured team while resolving to no target. It
  reports `team_source: "unset"` with `team_source_file: null` (nothing set the
  target) and warns that the export is shadowing the project value.
  `auth-check` sets `team_source_file` only when a project file supplied the
  resolved team, so the file never appears next to an environment-sourced or
  empty target.

Two layers enforce the fail-closed rule:

1. **Dispatcher** — `linear_guard_write_action "$action" "<write actions>" "$@"`
   runs right after the action is parsed, so a write refuses before any API
   call, including issue-identifier lookups. It reads only the first remaining
   argument, and only to let `<action> --help` through. It must never search
   argv for a `--team`: that token is just as likely to be free text in a
   comment body or an issue title, and honoring it would let user content open
   the gate.
   The list holds the write actions with **no** `--team` parser. The four that
   do parse one — `issues create`, `projects create`, `cycles create`,
   `labels create` — are omitted and instead call `linear_set_team_target` +
   `linear_require_team_target` immediately after their parse loop, still
   before any API call. Adding `--team` to another write means moving it out of
   the dispatcher list and into that pattern.
2. **Wire** — `graphql_query` refuses any document whose first token is
   `mutation` when `LINEAR_TEAM_TARGET` is empty. A write action missing from a
   dispatcher list degrades to a later refusal, never to a cross-workspace
   write. `linear_query_is_mutation` classifies by the leading token, so a
   document that buries its operation behind a leading fragment would evade it;
   `tests/graphql-document-classification.test.sh` fails the build if any
   document in `scripts/` takes that shape.

Read paths omit the team filter when the target is empty; they never send an
empty team name (which would match nothing) or a guessed one. `statuses` and
`cycles` reads apply `LINEAR_TEAM` as their default filter; `issues list` never
has — it filters by team only when `--team` is passed, and that asymmetry is
load-bearing for cross-team listings.

## What the Guard Does Not Cover

The guard proves a team is **configured**, not that a write lands in it. A
mutation addressed by an existing entity ID or identifier
(`issues update ABC-123`, `comments create ABC-123`, `issues archive`, relation
and project mutations) is routed by that ID inside whatever workspace the API
key reaches — the team target never constrains it. With `LINEAR_TEAM` set to one
team, `issues update <id-from-another-workspace> --state Done` still succeeds.

So the guarantee is: an unconfigured project cannot write to Linear at all, and
newly created entities land in the named team. A configured project handed a
foreign identifier will still act on it. Nothing here validates that an
identifier belongs to `LINEAR_TEAM`; that would cost a lookup on every mutation
and is not implemented.

Projects are seeded with `vstack.settings.toml.example`, which project-scope
`vstack add` / `vstack refresh` merge into `<project>/vstack.settings.toml`
without overwriting existing keys. The seeded `LINEAR_TEAM = ""` is inert: empty
is exactly the unset case, so an unedited seed keeps writes refused.
