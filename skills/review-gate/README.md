# review-gate

Org-wide PR review-gate engine. One vendored predicate script is the single
source of truth for "is this PR head reviewed?"; a commit status posted from
its verdict blocks merge without false reds; convergence scripts and two
scaffold workflows keep the status current as review state changes; an
offline decision-table selftest is the engine's portable proof, run ungated
in every consumer's CI.

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
- `vstack.settings.toml.example` — commented per-repo defaults merged into a
  project's `vstack.settings.toml` on install/refresh.

Per-repo trust lives in `vstack.settings.toml` (`REVIEW_GATE_*` keys) —
nothing repo-specific is hard-coded in the engine.
