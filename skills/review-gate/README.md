# review-gate

Merges gated on real review evidence for the exact PR head — not just green
CI. Repos whose reviews come from bots and humans that signal in different
ways (approvals, clean-analysis checks, comment-form passes) get one shared
predicate that answers "is this PR head reviewed?" and a commit status that
blocks merge until the answer is yes.

## What it offers

- **One evidence predicate, several accepted forms.** A trusted-reviewer
  approval is the obvious case, but the gate also accepts a trusted
  clean-analysis check-run/status succeeding on the exact head, and a
  comment-form clean pass from a trusted bot whose comment binds to that
  head's sha — for reviewers that comment but never file a formal approval.
- **Publisher-identity trust, opt-in status reject-list.** Trust keys on the
  login GitHub controls (a review's author, a check/status's exact
  context), never on comment text. Check-run evidence from `github-actions`
  is already unforgeable by PR content. Commit-status evidence is not: with
  the shipped defaults (`REVIEW_GATE_STATUS_PUBLISHER_REJECT` empty), a PR
  workflow holding `statuses:write` can mint a passing status under a
  trusted context. Repos where outage attestation isn't itself
  Actions-posted should set that reject-list to close the gap.
- **Outage attestation fallback.** A trusted orchestrator can post a
  genuine-silence attestation that substitutes for missing evidence — so a
  credit-exhausted or down reviewer never stalls every PR — but it never
  overrides an actual `changes-requested` or an unresolved thread.
- **Fails closed, never flips silently.** Changes-requested and unresolved
  review threads always block, even with other evidence present. A failed
  evidence read is loud (exit 2, no verdict) — pending, not a false green.
- **Convergence and refire.** As review state changes after the gate first
  posts, convergence scripts keep the status current and can rerun the
  gated jobs in place on the same head, capped against pathological
  ping-pong.
- **Offline decision-table selftest as portable proof.** No network, ~1s,
  runs ungated in every consumer's CI — a broken predicate reds its own
  selftest job rather than silently approving everything.

Nothing repo-specific is hard-coded in the engine: consumers vendor
`scripts/` via `vstack refresh` and configure trust per repo in
`vstack.settings.toml`.

## Who it's for

Any repo whose merge gate needs to key on real review evidence rather than
green CI alone — especially org-wide setups mixing bot reviewers (approve,
comment-only, or check-run-only) with human reviewers. It needs project
setup: a repo-owned CI gate job, one-time workflow scaffolds, and per-repo
`REVIEW_GATE_*` settings — see [`SKILL.md`](./SKILL.md) for the status model
and evidence sources, and [references/adoption.md](references/adoption.md)
for wiring.

Adoption follows one of three archetypes depending on what the repo already
has (a from-scratch adopter, a repo with a minimal local predicate, or a
repo with its own converge-based gate architecture) — `adoption.md` names
each and states which shape a given adoption PR follows.

## Files

- `SKILL.md` — status model, evidence sources, trust model, settings keys.
- `scripts/review-predicate.sh` — the predicate (verdict on stdout, exit 2 =
  no verdict, take no action).
- `scripts/approval-refire.sh` — status convergence + rerun-in-place for one
  PR head.
- `scripts/review-predicate-selftest.sh` — offline selftest; also generates
  approve/near-miss cases from the invoking repo's own `REVIEW_GATE_*`
  settings.
- `scripts/lib/settings.sh` — env > `vstack.settings.toml` > default
  resolution shared by the scripts.
- `templates/` — `approval-rerun.yml` / `approval-sweep.yml` one-time
  adoption scaffolds (repo-owned after copy).
- `references/adoption.md` — CI wiring (both trust postures), branch
  protection, merge-queue notes, per-repo settings, per-consumer adoption
  shapes.
- `references/settings.md` — full `REVIEW_GATE_*` key table and the
  security posture behind the trust-model settings.
- `vstack.settings.toml.example` — commented per-repo defaults merged into a
  project's `vstack.settings.toml` on install/refresh.
