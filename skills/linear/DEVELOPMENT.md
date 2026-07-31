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

Two layers enforce the fail-closed rule:

1. **Dispatcher** — `linear_guard_write_action "$action" "<write actions>" "$@"`
   runs right after the action is parsed, so a write refuses before any API
   call, including issue-identifier lookups. `--help` is exempt.
2. **Wire** — `graphql_query` refuses any document whose first token is
   `mutation` when `LINEAR_TEAM_TARGET` is empty. A write action missing from a
   dispatcher list degrades to a later refusal, never to a cross-workspace
   write.

Read paths omit the team filter when the target is empty; they never send an
empty team name (which would match nothing) or a guessed one.

Projects are seeded with `vstack.settings.toml.example`, which project-scope
`vstack add` / `vstack refresh` merge into `<project>/vstack.settings.toml`
without overwriting existing keys. The seeded `LINEAR_TEAM = ""` is inert: empty
is exactly the unset case, so an unedited seed keeps writes refused.
