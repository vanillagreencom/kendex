# Flightdeck run history plan

## Pre-execution context (updated 2026-05-19)

Do NOT act as Flightdeck master.
Start BACKUP-WAKE timer before orchestration.
Use 5-reviewer fan-out per substantive PR.
Do not run `/skill:flightdeck plan start` from child panes.

## Problem

Flightdeck needs clearer run identity and history behavior.

## Goals

Keep implementation items small and independently reviewable.

## Lifecycle changes

Archive and active-run behavior are design context for every safe item.

## Implementation phases

Intro text for the implementation workstream.

### Context

This workstream touches state and dashboard boundaries.

### Phase 1 — Run identity

Add run identity helpers and storage metadata.

#### Worktree
flightdeck-plan-run-identity

### Phase 2 — State command support

Expose run state commands.

#### Depends on
Phase 1 — Run identity

## Additional workstream — Pi followups

### Context

Pi extension followups stay separate from core run identity.

### Phase 8 — Codex provider shim

Prefix terminal provider errors with HTTP status.

### Phase 9 — Responsive skills rows

Clamp visible rows to terminal height.

## Acceptance criteria

Run history no longer appears as active supervision.

## Validation plan

Run focused tests and typecheck.

## Execution workflow

Flightdeck master should run `flightdeck plan watch` after spawning panes.
