# Decider

Architectural decision records for a project: numbered decision documents indexed in one `INDEX.md`, plus a `decisions` CLI that searches them. Agents use it to check whether an active decision already governs an area before proposing or implementing a change, and to record new decisions in a consistent format.

## How it works

Decisions live as `D001-descriptor.md` files beside an `INDEX.md` whose table carries one row per decision — date, ID, research link, one-line summary, rationale, revisit trigger, status, and a link to the document. The CLI parses that table, and keyword search also reads the linked documents, so a term that never made it into a one-line summary still finds the decision that governs it.

## Setup

Create the directory and an index:

```bash
mkdir -p docs/decisions
cat > docs/decisions/INDEX.md <<'EOF'
# Architectural Decision Log

| Date | ID | Research | Decision | Rationale | Revisit When | Status | Link |
|------|----|----------|----------|-----------|--------------|--------|------|
EOF
```

Verify with `decisions list && decisions next-id`.

## Customize

`decisions` looks upward from the working directory for `docs/decisions/`, `decisions/`, `doc/decisions/`, or `adr/` containing an `INDEX.md`; set `DECISIONS_DIR` in `vstack.settings.toml` under `[env]` to point somewhere else.

`next-id` follows whatever scheme the last index row uses, so `D001` and `ADR-0001` both carry forward. Set `DECISION_ID_PREFIX` and `DECISION_ID_WIDTH` to start an empty index on a specific scheme, or to switch schemes deliberately; without them, an ID with no numeric suffix is an error rather than a guess.

Requires `jq`.
