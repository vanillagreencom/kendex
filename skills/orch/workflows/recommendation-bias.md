# Recommendation Bias

Guidelines for categorizing review findings as fix (apply in PR) vs issue (track separately). Applies to any codebase — bias toward reliability when uncertain.

## Verification Prerequisite

Before classifying any comment as noise, stale, or not actionable — read the actual file(s) it references and verify against current code. A comment is only stale if the code proves it so. **No file read = no dismissal.**

## Decision Flow

For each potential suggestion, evaluate in order:

**1. Actionable?** Must have specific deliverable, observable impact, and bounded scope.
- Vague ("Add logging to X", "Add tests for X", "Document X", "Consider X") → **omit**
- Informational notes (not actionable) → **omit**
- Exception: automated regression detection (e.g., benchmark exit code 1) is never informational — classify per project's regression rules

**2. Related?** Does it relate to the issue being fixed or the code being changed?
- The test is semantic (about the problem or changes), not mechanical (is the file in the diff)
- Out-of-diff files documenting the mechanism being fixed → related
- Improvements to nearby code not about the problem being solved → unrelated
- Documentation and reference updates for changed APIs/patterns → always **`fix`** (never `issue`). Updated inline, same PR.
- Unrelated → **`issue`** regardless of size

**3. Size?** Can it be applied directly in this PR?
- Small, apply directly → **`fix`**
- Needs delegation, tracking, history, or new files → **`issue`**

### When Uncertain

- Category uncertain: prefer `fix` (if related)
- Relevance uncertain: prefer `issue`
- Neither fits: omit

## Category Signals

All assume the suggestion passed steps 1-2 (actionable and related).

| Signal | Category |
|--------|----------|
| Small, quick to apply | `fix` |
| Doc/reference updates for changed code | `fix` — always, regardless of size |
| Needs tracking, delegation, or history | `issue` |
| Architectural change, cross-component | `issue` |
| Test coverage (add to existing test) | `fix` |
| Test coverage (new file/suite/scenarios) | `issue` |
| Performance fix in touched code | `fix` |
| Performance work needing benchmarks | `issue` |
| Error handling gaps | `issue` — silent failures have real cost |
| Security vulnerabilities | `fix` if quick, else `issue` — never skip |
| Data validation gaps | `fix` if quick, else `issue` — cascading failures |
| Same claim/enumeration drift found ≥2 rounds | `fix` as a structural close (derive, bind, or delete the claim), not an `issue` — prose-level fixes regenerate the finding next round; by-construction fixes converge |

An `issue` signal is necessary but not sufficient: the item must also clear the Filing Bar below, or it is absorbed or dropped rather than filed.

## Issue Scope

- **In-scope**: Part of this PR's work, big enough for sub-issue tracking. Child of parent issue.
- **Out-of-scope**: Worth doing, not part of this PR. Tracked separately.

### Bundle Attachment

When a same-surface bundle or umbrella parent already exists in the tracker, residue files as a child/related of it — a later audit should never have to re-parent a PR's standalone leftovers. A standalone filing needs a stated reason (new surface, or nothing to attach to).

## Priority

1-4 scale. Review agents typically assign 2-4.

| Pri | Meaning | Use When |
|-----|---------|----------|
| P1 | Urgent | Blocks critical path |
| P2 | High | Important, architecture |
| P3 | Normal | Standard work |
| P4 | Low | Nice-to-have, cleanup |

## Filing Bar

File an `issue` only for:

- **Behavioral defects outside the PR's scope** — wrong behavior a user or caller can hit, not in this PR's charter to fix.
- **est≥2 refactors** — real restructuring work too large to absorb in-PR.
- **Decision revisits** — a recorded decision the finding argues should change.
- **Unexplained anomalies with evidence** — observed and reproducible, cause unknown.

P4 polish never files: absorb it in-PR when it is est-1 and related, otherwise drop it with a one-line note in the review summary. Vague items are noise, not visibility. The bar moves for polish, not defects — anything that is a defect still routes per the signals above.
