#!/usr/bin/env bash
# The engine's core test: run the offline selftest end-to-end (it is
# self-contained by design — gh shim + fixtures, no network) and prove both
# of its layers:
#   1. with no repo settings, the full decision table passes on the built-in
#      defaults;
#   2. with a repo-configured trust surface (different bot, different
#      contexts, non-default floor/skip patterns/trust list), the configured
#      layer regenerates its approve/near-miss battery from THOSE values —
#      a repo trusting a different bot tests its own config, not defaults.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELFTEST="$(cd "$TEST_DIR/../scripts" && pwd)/review-predicate-selftest.sh"

fail=0
note() { echo "FAIL: $1"; fail=1; }

[ -x "$SELFTEST" ] || { echo "FAIL: not executable: $SELFTEST"; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --- layer 1: built-in defaults (no settings file resolvable) ---------------
mkdir -p "$work/defaults"
if ! (cd "$work/defaults" && "$SELFTEST") >"$work/defaults.out" 2>&1; then
  cat "$work/defaults.out"
  note "selftest failed under built-in defaults"
fi
default_cases="$(sed -n 's/^review-predicate selftest: \([0-9]*\) case(s), all pass$/\1/p' "$work/defaults.out")"
if [ -z "$default_cases" ] || [ "$default_cases" -lt 50 ]; then
  note "expected >=50 default cases with a pass summary, got '${default_cases:-none}'"
fi
grep -q "rate-limited 'pass' check-run is NOT evidence" "$work/defaults.out" \
  || note "rate-limited-pass fixture case missing"
grep -q "approval NOT superseded by a later COMMENTED" "$work/defaults.out" \
  || note "approval non-supersession case missing"
grep -q "UNTRUSTED login's review is not evidence" "$work/defaults.out" \
  || note "review-object trust-list case missing"
grep -q "publisher filter set: github-actions-minted trusted status is not evidence" "$work/defaults.out" \
  || note "status publisher-filter near-miss case missing"
grep -q "publisher filter set: github-actions-minted outage attestation is not evidence" "$work/defaults.out" \
  || note "outage publisher-filter near-miss case missing"
grep -q "publisher filter unset: github-actions-minted status counts" "$work/defaults.out" \
  || note "publisher-filter default-unchanged case missing"
grep -q "publisher filter set: an outage attestation with NO creator login is not evidence" "$work/defaults.out" \
  || note "outage creator-less case missing (outage read is a separate jq implementation)"
grep -q "publisher filter unset: github-actions-minted outage attestation counts" "$work/defaults.out" \
  || note "outage default-unchanged case missing (outage read is a separate jq implementation)"

# --- layer 1b: the committed-mode-typo guard must itself be falsifiable -----
# The selftest validates the repo's ACTIVE REVIEW_GATE_MODE standalone (a
# committed typo fails the suite pre-merge). Prove the guard fires: a
# planted invalid mode must fail the suite naming the key — otherwise
# deleting the guard would leave everything green.
mkdir -p "$work/modetypo"
if (cd "$work/modetypo" && REVIEW_GATE_MODE=offf "$SELFTEST") >"$work/modetypo.out" 2>&1; then
  note "selftest passed with a planted invalid REVIEW_GATE_MODE — the committed-typo guard no longer fires"
else
  grep -q "REVIEW_GATE_MODE" "$work/modetypo.out"     || note "the planted-invalid-mode failure does not name REVIEW_GATE_MODE"
fi

# --- layer 2: the selftest must exercise CONFIGURED values ------------------
mkdir -p "$work/configured"
cat >"$work/configured/vstack.settings.toml" <<'EOF'
[env]
REVIEW_GATE_TRUSTED_STATUS_CONTEXTS = "Acme Review; Beta Scan"
REVIEW_GATE_CHECKRUN_SKIP_PATTERNS = "quota exceeded"
REVIEW_GATE_COMMENT_REVIEWERS = "acme-reviewer[bot]:Analysis (clean) for commit"
REVIEW_GATE_SHA_PREFIX_FLOOR = "9"
REVIEW_GATE_OUTAGE_CONTEXT = "acme-outage"
REVIEW_GATE_STATUS_PUBLISHER_REJECT = "github-actions[bot]"
REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS = "acme-reviewer[bot];human-lead"
REVIEW_GATE_REVIEW_OBJECT_MIN_STATE = "approved"
REVIEW_GATE_THREADS = "off"
REVIEW_GATE_API_ATTEMPTS = "2"
REVIEW_GATE_CARRY_FORWARD = "docs"
EOF
if ! (cd "$work/configured" && "$SELFTEST") >"$work/configured.out" 2>&1; then
  cat "$work/configured.out"
  note "selftest failed under a configured trust surface"
fi
configured_cases="$(sed -n 's/^review-predicate selftest: \([0-9]*\) case(s), all pass$/\1/p' "$work/configured.out")"
if [ -z "$configured_cases" ] || [ "$configured_cases" -le "${default_cases:-0}" ]; then
  note "configured run should add cases beyond the default run (default=${default_cases:-?}, configured=${configured_cases:-none})"
fi
# The battery must be generated FROM the configured values: each configured
# context and the configured comment reviewer must appear as case subjects,
# including their near-misses.
grep -q '\[Acme Review\] clean commit status at head' "$work/configured.out" \
  || note "configured context 'Acme Review' not exercised"
grep -q '\[Beta Scan\] check-run under a DIFFERENT name' "$work/configured.out" \
  || note "configured context 'Beta Scan' near-miss not exercised"
grep -q "\[acme-reviewer\[bot\]\] SAME BODY, wrong author" "$work/configured.out" \
  || note "configured comment reviewer near-miss battery not exercised"
grep -q "success check-run but output says 'quota exceeded'" "$work/configured.out" \
  || note "configured skip pattern not exercised"
grep -q "login outside the repo trust list is not evidence" "$work/configured.out" \
  || note "configured review-object trust list near-miss not exercised"
grep -q "outage attestation (acme-outage)" "$work/configured.out" \
  || note "configured outage context not exercised"
grep -q '\[Acme Review\] status minted by a rejected publisher is not evidence' "$work/configured.out" \
  || note "configured publisher reject-list near-miss not exercised"
grep -q "outage attestation from a rejected publisher is not evidence" "$work/configured.out" \
  || note "configured outage publisher reject-list near-miss not exercised"
grep -q "configured: threads=off" "$work/configured.out" \
  || note "configured threads=off posture not exercised"
grep -q "configured: a transient read failure survives the repo's retry budget" "$work/configured.out" \
  || note "configured retry budget not exercised"
grep -q "configured: unresolved thread fails closed" "$work/defaults.out" \
  || note "default threads=enforce posture not exercised"
grep -q "configured: carry-forward (docs) — identical tree carries" "$work/configured.out" \
  || note "configured carry-forward posture not exercised"
grep -q "carry off (default): the same docs delta does NOT carry" "$work/defaults.out" \
  || note "carry-forward off-default near-miss missing"

# --- layer 2b: EVERY committed carry-exclude glob is exercised --------------
# One battery case per committed glob — a later typo'd addition must not
# hide behind an earlier glob's green — and a leading-'/' glob (which can
# never match a repository-relative compare filename) must FAIL the suite,
# not skip silently.
mkdir -p "$work/excludes"
# BSD/macOS sed has no \n replacement extension — build fixtures with
# grep -v + printf instead.
grep -v '^REVIEW_GATE_CARRY_FORWARD = ' "$work/configured/vstack.settings.toml" \
  >"$work/excludes/vstack.settings.toml"
printf 'REVIEW_GATE_CARRY_FORWARD = "docs"\nREVIEW_GATE_CARRY_FORWARD_EXCLUDE = "*AGENTS.md;guides/*"\n' \
  >>"$work/excludes/vstack.settings.toml"
if ! (cd "$work/excludes" && "$SELFTEST") >"$work/excludes.out" 2>&1; then
  cat "$work/excludes.out"
  note "selftest failed under a committed carry-exclude list"
fi
# Require the SUCCESSFUL probe phrasing ("matches '<path>', refusing the
# carry"), not the bare "matches" stem — the selftest's own skip note
# ("matches NO tracked … not exercised here") shares that stem, so the loose
# grep stayed green when a glob produced no probe at all.
grep -q "carry-exclude — '\*AGENTS.md' matches '.*', refusing the carry" "$work/excludes.out" \
  || note "committed glob '*AGENTS.md' not exercised with a refusing probe"
grep -q "carry-exclude — 'guides/\*' matches '.*', refusing the carry" "$work/excludes.out" \
  || note "committed glob 'guides/*' not exercised with a refusing probe (every glob must probe, not just the first)"
grep -q "outside every committed glob and still carries" "$work/excludes.out" \
  || note "committed exclude-free carry case not exercised"

# --- layer 2c: a broken ls-files fails loud, never a hermetic fallback ------
# A git shim delegates everything except `ls-files` (which fails): inside a
# repository whose tracked read is broken, the selftest must FAIL with the
# refusing-to-degrade diagnostic instead of quietly falling back to synthetic
# probes. Red-first proof of the staged-status fix in load_exclude_tracked —
# the original `git ls-files -z | tr` assignment took tr's status, so a
# failed ls-files vanished and coverage shrank exactly when git was broken.
mkdir -p "$work/brokengit/bin" "$work/brokengit/repo"
real_git="$(command -v git)"
cat >"$work/brokengit/bin/git" <<BROKENGIT
#!/usr/bin/env bash
# The subcommand may ride behind global options (git -C <root> ls-files),
# so scan every argument rather than pinning position 1.
for _a in "\$@"; do
  if [ "\$_a" = "ls-files" ]; then
    echo "fatal: planted index failure" >&2
    exit 128
  fi
done
exec "$real_git" "\$@"
BROKENGIT
chmod +x "$work/brokengit/bin/git"
(cd "$work/brokengit/repo" && "$real_git" init -q .)
# The tracked-probe battery only runs under an ACTIVE carry-exclude list —
# reuse the committed-glob fixture settings.
cp "$work/excludes/vstack.settings.toml" "$work/brokengit/repo/vstack.settings.toml"
if (cd "$work/brokengit/repo" && PATH="$work/brokengit/bin:$PATH" "$SELFTEST") \
  >"$work/brokengit.out" 2>&1; then
  note "selftest passed inside a repository whose ls-files is broken — the refusing-to-degrade guard no longer fires"
else
  grep -q "refusing to degrade to synthetic probes" "$work/brokengit.out" \
    || note "broken-ls-files failure does not carry the refusing-to-degrade diagnostic"
fi

# --- layer 2d: a failed mktemp is unverifiable, same refuse-to-degrade -----
# A PATH shim fails only the NO-ARGUMENT mktemp (the staging-file call in
# load_exclude_tracked) while delegating `mktemp -d` and every other form
# (the selftest's own work dir needs -d at startup). No staging file means
# the tracked read cannot be verified, and unverifiable must take the same
# loud branch as failed — never a silent slide into hermetic probing.
mkdir -p "$work/brokenmktemp/bin" "$work/brokenmktemp/repo"
real_mktemp="$(command -v mktemp)"
cat >"$work/brokenmktemp/bin/mktemp" <<BROKENMKTEMP
#!/usr/bin/env bash
if [ \$# -eq 0 ]; then
  echo "mktemp: planted tmpdir failure" >&2
  exit 1
fi
exec "$real_mktemp" "\$@"
BROKENMKTEMP
chmod +x "$work/brokenmktemp/bin/mktemp"
(cd "$work/brokenmktemp/repo" && git init -q .)
cp "$work/excludes/vstack.settings.toml" "$work/brokenmktemp/repo/vstack.settings.toml"
if (cd "$work/brokenmktemp/repo" && PATH="$work/brokenmktemp/bin:$PATH" "$SELFTEST") \
  >"$work/brokenmktemp.out" 2>&1; then
  note "selftest passed with an unverifiable tracked read (mktemp failed) — the refuse-to-degrade branch no longer covers it"
else
  grep -q "refusing to degrade to synthetic probes" "$work/brokenmktemp.out" \
    || note "broken-mktemp failure does not carry the refusing-to-degrade diagnostic"
  # The CAUSE must be the right one: reverting the cause-carrying flag to
  # the old hard-coded git advice would still print the generic suffix, so
  # require the mktemp wording and reject the git-failure diagnosis.
  grep -q "staging file creation failed (mktemp)" "$work/brokenmktemp.out" \
    || note "broken-mktemp failure does not name the mktemp/staging cause"
  # Absence assertion via explicit status: 0 = misattribution present,
  # >=2 = grep itself failed to read — both are failures, distinctly named.
  set +e
  grep -q "'git ls-files' failed" "$work/brokenmktemp.out"
  _g=$?
  set -e
  if [ "$_g" -eq 0 ]; then
    note "broken-mktemp failure misattributes the cause to git ls-files"
  elif [ "$_g" -ge 2 ]; then
    note "could not read brokenmktemp.out for the misattribution check (grep exit $_g)"
  fi
fi

# --- layer 2e: the harness namespace is not the over-broad namespace --------
# Hermetic fixture with `carry-probe*` as the ONLY exclusion: it matches one
# synthetic candidate family but not the other, so the run must PASS with the
# exclude-free carry case exercised. Reproduces the candidate-prefix
# collision this suite hardened against — with both candidates under
# `carry-probe*`, this fixture false-FAILed as "can never apply".
mkdir -p "$work/probeglob"
grep -v '^REVIEW_GATE_CARRY_FORWARD = ' "$work/configured/vstack.settings.toml" \
  >"$work/probeglob/vstack.settings.toml"
printf 'REVIEW_GATE_CARRY_FORWARD = "docs"\nREVIEW_GATE_CARRY_FORWARD_EXCLUDE = "carry-probe*"\n' \
  >>"$work/probeglob/vstack.settings.toml"
if ! (cd "$work/probeglob" && "$SELFTEST") >"$work/probeglob.out" 2>&1; then
  cat "$work/probeglob.out"
  note "selftest failed under a harness-namespace exclusion glob (carry-probe*) — the candidate-prefix collision is back"
fi
grep -q "outside every committed glob and still carries" "$work/probeglob.out" \
  || note "harness-namespace fixture did not exercise the exclude-free carry case"

# --- layer 2g: tracked evidence is ROOT-relative and dead globs fail -------
# One fixture repo, three runs. (a) From a SUBDIRECTORY the battery must
# still probe the full tracked tree — the pre-fix subtree-scoped ls-files
# quietly downgraded every glob to its no-match note. (b) An exclusion glob
# matching no tracked path is dead config and must FAIL undeclared. (c) The
# same glob declared prophylactic notes and passes.
mkdir -p "$work/rooted/repo/guides" "$work/rooted/repo/sub"
(cd "$work/rooted/repo" && git init -q . \
  && printf '# intro\n' > guides/intro.md \
  && printf '# readme\n' > README.md \
  && git add guides/intro.md README.md \
  && git -c user.email=t@t -c user.name=t commit -qm probe)
grep -v '^REVIEW_GATE_CARRY_FORWARD = ' "$work/configured/vstack.settings.toml" \
  >"$work/rooted/repo/vstack.settings.toml"
printf 'REVIEW_GATE_CARRY_FORWARD = "docs"\nREVIEW_GATE_CARRY_FORWARD_EXCLUDE = "guides/*"\n' \
  >>"$work/rooted/repo/vstack.settings.toml"
if ! (cd "$work/rooted/repo/sub" && REVIEW_GATE_SETTINGS_FILE="$work/rooted/repo/vstack.settings.toml" "$SELFTEST") \
  >"$work/rooted.out" 2>&1; then
  cat "$work/rooted.out"
  note "selftest failed when run from a repository SUBDIRECTORY"
fi
grep -q "evidence mode: tracked" "$work/rooted.out" \
  || note "subdirectory run did not report tracked evidence mode"
grep -q "carry-exclude — 'guides/\*' matches 'guides/intro.md', refusing the carry" "$work/rooted.out" \
  || note "subdirectory run did not probe the full tracked tree (root-relative evidence base regressed)"

printf 'REVIEW_GATE_CARRY_FORWARD = "docs"\nREVIEW_GATE_CARRY_FORWARD_EXCLUDE = "gudies/*"\n' \
  >"$work/rooted/typo.toml"
grep -v '^REVIEW_GATE_CARRY_FORWARD = ' "$work/configured/vstack.settings.toml" \
  >>"$work/rooted/typo.toml"
if (cd "$work/rooted/repo" && REVIEW_GATE_SETTINGS_FILE="$work/rooted/typo.toml" "$SELFTEST") \
  >"$work/rootedtypo.out" 2>&1; then
  note "selftest passed with a typo'd exclusion glob matching nothing — the dead-glob gate no longer fires"
else
  grep -q "matches NO tracked carry-class" "$work/rootedtypo.out" \
    || note "the typo'd-glob failure does not carry the no-match diagnostic"
fi

printf 'REVIEW_GATE_CARRY_FORWARD = "docs"\nREVIEW_GATE_CARRY_FORWARD_EXCLUDE = "gudies/*"\nREVIEW_GATE_CARRY_FORWARD_EXCLUDE_PROPHYLACTIC = "gudies/*"\n' \
  >"$work/rooted/declared.toml"
grep -v '^REVIEW_GATE_CARRY_FORWARD = ' "$work/configured/vstack.settings.toml" \
  >>"$work/rooted/declared.toml"
if ! (cd "$work/rooted/repo" && REVIEW_GATE_SETTINGS_FILE="$work/rooted/declared.toml" "$SELFTEST") \
  >"$work/rooteddecl.out" 2>&1; then
  cat "$work/rooteddecl.out"
  note "selftest failed with a DECLARED prophylactic glob — the declaration is not honored"
fi
grep -q "DECLARED prophylactic" "$work/rooteddecl.out" \
  || note "declared prophylactic glob did not report the declared note"

# A structurally universal exclusion must FAIL in TRACKED mode too — with
# one committed, no path today or ever can carry, so the tracked-mode
# "future files still carry" note would understate a dead config. Run inside
# a real repository with a tracked carry-class file and a '*' exclusion.
mkdir -p "$work/trackeduniv/repo"
(cd "$work/trackeduniv/repo" && git init -q . \
  && printf '# probe\n' > README.md \
  && git add README.md \
  && git -c user.email=t@t -c user.name=t commit -qm probe)
grep -v '^REVIEW_GATE_CARRY_FORWARD = ' "$work/configured/vstack.settings.toml" \
  >"$work/trackeduniv/repo/vstack.settings.toml"
printf 'REVIEW_GATE_CARRY_FORWARD = "docs"\nREVIEW_GATE_CARRY_FORWARD_EXCLUDE = "*"\n' \
  >>"$work/trackeduniv/repo/vstack.settings.toml"
if (cd "$work/trackeduniv/repo" && "$SELFTEST") >"$work/trackeduniv.out" 2>&1; then
  note "selftest passed with a '*' exclusion in TRACKED mode — structural universality is only enforced hermetically"
else
  grep -q "can never apply" "$work/trackeduniv.out" \
    || note "the tracked-mode '*' failure does not carry the can-never-apply diagnostic"
fi

# --- layer 2f: probe exhaustion without a structurally universal glob ------
# A glob set spanning BOTH harness namespaces exhausts every synthetic
# candidate while ordinary paths still carry — that is UNPROVEN universality,
# not an over-broad failure. The run must PASS and say so out loud; only a
# structurally universal all-wildcard entry (only '*'/'?' characters, at
# least one '*', at most one '?' — '*', '***', '?*', '*?') may fail as
# "can never apply" (layer below).
mkdir -p "$work/bothns"
grep -v '^REVIEW_GATE_CARRY_FORWARD = ' "$work/configured/vstack.settings.toml" \
  >"$work/bothns/vstack.settings.toml"
printf 'REVIEW_GATE_CARRY_FORWARD = "docs"\nREVIEW_GATE_CARRY_FORWARD_EXCLUDE = "carry-probe*;unexcluded-sample*"\n' \
  >>"$work/bothns/vstack.settings.toml"
if ! (cd "$work/bothns" && "$SELFTEST") >"$work/bothns.out" 2>&1; then
  cat "$work/bothns.out"
  note "selftest failed under a both-namespaces exclusion set — probe exhaustion is being read as proof of universality again"
fi
grep -q "universality is UNPROVEN" "$work/bothns.out" \
  || note "both-namespaces fixture did not report the unproven-universality note"

# Structural universality is not spelled '*' alone: any all-wildcard entry
# with at least one asterisk ('***' here) matches every non-empty path under
# the predicate's bash-case matcher and must FAIL as over-broad, never be
# downgraded to the unproven note.
mkdir -p "$work/allstars"
grep -v '^REVIEW_GATE_CARRY_FORWARD = ' "$work/configured/vstack.settings.toml" \
  >"$work/allstars/vstack.settings.toml"
printf 'REVIEW_GATE_CARRY_FORWARD = "docs"\nREVIEW_GATE_CARRY_FORWARD_EXCLUDE = "***"\n' \
  >>"$work/allstars/vstack.settings.toml"
if (cd "$work/allstars" && "$SELFTEST") >"$work/allstars.out" 2>&1; then
  note "selftest passed with a '***' exclusion — the all-wildcard universal shape is being read as unproven"
else
  grep -q "can never apply" "$work/allstars.out" \
    || note "the '***' failure does not carry the can-never-apply diagnostic"
fi

# The '?' boundary, both directions: exactly one '?' beside a star is still
# universal (every path has one character) and must FAIL; two '?'s impose a
# minimum length one-character paths escape and must downgrade to UNPROVEN.
mkdir -p "$work/oneq" "$work/twoq"
grep -v '^REVIEW_GATE_CARRY_FORWARD = ' "$work/configured/vstack.settings.toml" \
  >"$work/oneq/vstack.settings.toml"
printf 'REVIEW_GATE_CARRY_FORWARD = "docs"\nREVIEW_GATE_CARRY_FORWARD_EXCLUDE = "?*"\n' \
  >>"$work/oneq/vstack.settings.toml"
if (cd "$work/oneq" && "$SELFTEST") >"$work/oneq.out" 2>&1; then
  note "selftest passed with a '?*' exclusion — the one-? universal shape is being read as unproven"
else
  grep -q "can never apply" "$work/oneq.out" \
    || note "the '?*' failure does not carry the can-never-apply diagnostic"
fi
# '??*' excludes every >=2-char filename, so it legitimately breaks the
# run's own carry-positive battery — the run's EXIT is not the assertion
# here. The classification is: '??*' must take the UNPROVEN note, never the
# can-never-apply FAIL (one-character paths escape its minimum length).
grep -v '^REVIEW_GATE_CARRY_FORWARD = ' "$work/configured/vstack.settings.toml" \
  >"$work/twoq/vstack.settings.toml"
printf 'REVIEW_GATE_CARRY_FORWARD = "docs"\nREVIEW_GATE_CARRY_FORWARD_EXCLUDE = "??*"\n' \
  >>"$work/twoq/vstack.settings.toml"
(cd "$work/twoq" && "$SELFTEST") >"$work/twoq.out" 2>&1 || true
grep -q "universality is UNPROVEN" "$work/twoq.out" \
  || note "the '??*' fixture did not report the unproven-universality note"
# Same explicit-status shape as the misattribution check above.
set +e
grep -q "can never apply" "$work/twoq.out"
_g=$?
set -e
if [ "$_g" -eq 0 ]; then
  note "'??*' was over-classified as structurally universal (minimum-length patterns are not)"
elif [ "$_g" -ge 2 ]; then
  note "could not read twoq.out for the over-classification check (grep exit $_g)"
fi

# One combined FAILING run pins BOTH guards (each fixture run replays the
# full decision table, so failure cases share a run): a leading-'/' glob can
# never match a repository-relative compare filename (dead anchoring), and a
# '*' exclusion swallowing every carry-class probe path means the enabled
# class can never apply (over-broad).
mkdir -p "$work/deadglob"
grep -v '^REVIEW_GATE_CARRY_FORWARD = ' "$work/configured/vstack.settings.toml" \
  >"$work/deadglob/vstack.settings.toml"
printf 'REVIEW_GATE_CARRY_FORWARD = "docs"\nREVIEW_GATE_CARRY_FORWARD_EXCLUDE = "/docs/*;*"\n' \
  >>"$work/deadglob/vstack.settings.toml"
if (cd "$work/deadglob" && "$SELFTEST") >"$work/deadglob.out" 2>&1; then
  note "selftest passed with dead ('/docs/*') and over-broad ('*') carry-excludes — the guards no longer fire"
else
  grep -q "leading '/'" "$work/deadglob.out" \
    || note "the dead-glob failure does not explain the leading-'/' anchoring"
  grep -q "can never apply" "$work/deadglob.out" \
    || note "the over-broad failure does not explain that the carry class is dead"
fi

if [ "$fail" -ne 0 ]; then
  echo "review-predicate-selftest.test: FAIL"
  exit 1
fi
echo "pass: review-predicate-selftest ($default_cases default / $configured_cases configured cases)"
