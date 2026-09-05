# Decider

Decision records and a search CLI for project maintainers. Agents can find an existing decision before proposing a change.

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

## Features

- Search decision summaries and their linked documents.
- List records and find the next available decision ID.
- Create, revise and supersede records through shared workflows.

## How it works

Each decision has a markdown document. An index links to each document and records its status. The CLI searches the index and the linked text. An agent follows the creation workflow when you approve a new record.

## Settings

- `DECISIONS_DIR`: where the records live, when auto-discovery of `docs/decisions/`, `decisions/`, `doc/decisions/` or `adr/` does not fit. Set it in `kendex.settings.toml` under `[env]`.
- `DECISION_ID_PREFIX`, `DECISION_ID_WIDTH`: the ID scheme for an empty index or a deliberate switch. Without them `next-id` follows the last index row, so `D001` and `ADR-0001` both carry forward.

Every key and its default: `decisions --help`.
