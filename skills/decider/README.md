# Decider

Architectural decision document management — templates, creation workflows, search CLI, and supersession tracking.

## Setup

1. Create a decisions directory with an `INDEX.md`:

```bash
mkdir -p docs/decisions
cat > docs/decisions/INDEX.md <<'EOF'
# Architectural Decision Log

| Date | ID | Research | Decision | Rationale | Revisit When | Status | Link |
|------|----|----------|----------|-----------|--------------|--------|------|
EOF
```

2. Verify: `decisions list && decisions next-id`

Optionally set `DECISIONS_DIR` in committed `vstack.settings.toml` under `[env]` to override auto-discovery (searches `docs/decisions/`, `decisions/`, `doc/decisions/`, `adr/`). Existing `.env.local` overrides still work.

`decisions next-id` derives the active ID scheme from the last populated `INDEX.md` ID-column value, preserving schemes such as `D001` or `ADR-0001` and ignoring ID-looking text in prose cells. If that value has no numeric suffix, `next-id` fails with a configuration hint instead of guessing. For an empty index or an intentional scheme switch, set `DECISION_ID_PREFIX` and `DECISION_ID_WIDTH` under `[env]`.

Before the directory is initialized, `search` and `list` return an empty result (`[]`, exit 0) with a note on stderr; `next-id` and `get` error until it exists.

## Decision Templates

| Template | Lines | When to Use |
|----------|-------|-------------|
| Minimal | 15-30 | Single choice, clear winner |
| Standard | 80-200 | Multiple alternatives, comparison tables |
| Comprehensive | 200-600 | Architecture-level, multi-concern |

## Dependencies

- `bash` 4+
- `jq`
- GNU `grep` with `-P` (PCRE): available as `grep`, `ggrep`, or Homebrew `gnubin/grep`
