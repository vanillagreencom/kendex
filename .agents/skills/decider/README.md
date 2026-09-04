# Decider

Architectural decision records for a project: numbered decision documents indexed in one `INDEX.md`, plus a `decisions` CLI that searches them. For a project that wants agents to check what already governs an area before proposing a change, and to record new decisions in one format.

## Install

```bash
kendex add vanillagreencom/kendex --skill decider
```

Needs `jq`. Then create the directory and an empty index:

```bash
mkdir -p docs/decisions
cat > docs/decisions/INDEX.md <<'EOF'
# Architectural Decision Log

| Date | ID | Research | Decision | Rationale | Revisit When | Status | Link |
|------|----|----------|----------|-----------|--------------|--------|------|
EOF
```

Confirm with `decisions list && decisions next-id`.

## What it does

- Ranked keyword and regex search over the index and the decision documents themselves.
- `list`, `get`, `next-id`, and a lookup by linked issue.
- Workflows for creating a decision and for superseding or revisiting one.
- A decision format and templates every record follows.

## How it works

Decisions live as `D001-descriptor.md` files beside an `INDEX.md` whose table carries one row per decision. The CLI parses that table, and keyword search also reads the linked documents, so a term missing from a one-line summary still finds the decision that governs it. Agents never create a decision without explicit approval; the rule is in [SKILL.md](SKILL.md) § Approval.

## Customise

- `DECISIONS_DIR`: where the records live, when auto-discovery of `docs/decisions/`, `decisions/`, `doc/decisions/` or `adr/` does not fit. Set it in `kendex.settings.toml` under `[env]`.
- `DECISION_ID_PREFIX`, `DECISION_ID_WIDTH`: the ID scheme for an empty index or a deliberate switch. Without them `next-id` follows the last index row, so `D001` and `ADR-0001` both carry forward.

Every key and its default: `decisions --help`.
