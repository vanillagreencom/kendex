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
# The SUBCOMMAND may ride behind global options (git -C <root> ls-files):
# skip option flags and their operands, and fail only when the first
# non-option argument — the actual subcommand — is ls-files, so a path
# operand literally named "ls-files" cannot false-trigger.
_sub=""
_skip=""
for _a in "\$@"; do
  if [ -n "\$_skip" ]; then _skip=""; continue; fi
  case "\$_a" in
    -C|--git-dir|--work-tree|-c) _skip=1 ;;
    -*) ;;
    *) _sub="\$_a"; break ;;
  esac
done
if [ "\$_sub" = "ls-files" ]; then
  echo "fatal: planted index failure" >&2
  exit 128
fi
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

# --- layer 2c2: rev-parse's STATUS decides the root, never its stdout ------
# A git shim fails `rev-parse --show-toplevel` (exit 128) while PLANTING a
# path on stdout, delegating everything else (--is-inside-work-tree must
# still pass to reach the root resolution). An output-only guard accepts
# the planted root and marches on to ls-files against a directory git never
# vouched for; the producer's own exit status must refuse it.
mkdir -p "$work/brokenroot/bin" "$work/brokenroot/repo"
cat >"$work/brokenroot/bin/git" <<BROKENROOT
#!/usr/bin/env bash
_sub=""
_skip=""
for _a in "\$@"; do
  if [ -n "\$_skip" ]; then _skip=""; continue; fi
  case "\$_a" in
    -C|--git-dir|--work-tree|-c) _skip=1 ;;
    -*) ;;
    *) _sub="\$_a"; break ;;
  esac
done
if [ "\$_sub" = "rev-parse" ]; then
  for _a in "\$@"; do
    if [ "\$_a" = "--show-toplevel" ]; then
      echo "/planted/never-vouched-root"
      exit 128
    fi
  done
fi
exec "$real_git" "\$@"
BROKENROOT
chmod +x "$work/brokenroot/bin/git"
(cd "$work/brokenroot/repo" && "$real_git" init -q .)
cp "$work/excludes/vstack.settings.toml" "$work/brokenroot/repo/vstack.settings.toml"
if (cd "$work/brokenroot/repo" && PATH="$work/brokenroot/bin:$PATH" "$SELFTEST") \
  >"$work/brokenroot.out" 2>&1; then
  note "selftest passed with a failing rev-parse that planted a root on stdout — git's status no longer decides the root"
else
  grep -q "could not resolve the repository root" "$work/brokenroot.out" \
    || note "planted-root failure does not carry the root-resolution diagnostic"
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
  >"$work/rooted/repo/typo.settings.toml"
grep -v '^REVIEW_GATE_CARRY_FORWARD = ' "$work/configured/vstack.settings.toml" \
  >>"$work/rooted/repo/typo.settings.toml"
if (cd "$work/rooted/repo" && REVIEW_GATE_SETTINGS_FILE="$work/rooted/repo/typo.settings.toml" "$SELFTEST") \
  >"$work/rootedtypo.out" 2>&1; then
  note "selftest passed with a typo'd exclusion glob matching nothing — the dead-glob gate no longer fires"
else
  grep -q "matches NO tracked carry-class" "$work/rootedtypo.out" \
    || note "the typo'd-glob failure does not carry the no-match diagnostic"
fi

printf 'REVIEW_GATE_CARRY_FORWARD = "docs"\nREVIEW_GATE_CARRY_FORWARD_EXCLUDE = "gudies/*"\nREVIEW_GATE_CARRY_FORWARD_EXCLUDE_PROPHYLACTIC = "gudies/*"\n' \
  >"$work/rooted/repo/declared.settings.toml"
grep -v '^REVIEW_GATE_CARRY_FORWARD = ' "$work/configured/vstack.settings.toml" \
  >>"$work/rooted/repo/declared.settings.toml"
if ! (cd "$work/rooted/repo" && REVIEW_GATE_SETTINGS_FILE="$work/rooted/repo/declared.settings.toml" "$SELFTEST") \
  >"$work/rooteddecl.out" 2>&1; then
  cat "$work/rooteddecl.out"
  note "selftest failed with a DECLARED prophylactic glob — the declaration is not honored"
fi
grep -q "DECLARED prophylactic" "$work/rooteddecl.out" \
  || note "declared prophylactic glob did not report the declared note"

# A glob matching tracked paths only OUTSIDE the enabled carry classes is
# INERT, not dead: it provably names real paths (no typo to catch), and the
# prophylactic declaration would be false for it (its contract is "no
# tracked match today"). The run must PASS with the inert note — neither
# the dead-glob FAIL nor a demand for a false declaration.
(cd "$work/rooted/repo" && printf '[package]\n' > Cargo.toml \
  && git add Cargo.toml \
  && git -c user.email=t@t -c user.name=t commit -qm cargo)
printf 'REVIEW_GATE_CARRY_FORWARD = "docs"\nREVIEW_GATE_CARRY_FORWARD_EXCLUDE = "*Cargo.toml"\n' \
  >"$work/rooted/repo/inert.settings.toml"
grep -v '^REVIEW_GATE_CARRY_FORWARD = ' "$work/configured/vstack.settings.toml" \
  >>"$work/rooted/repo/inert.settings.toml"
if ! (cd "$work/rooted/repo" && REVIEW_GATE_SETTINGS_FILE="$work/rooted/repo/inert.settings.toml" "$SELFTEST") \
  >"$work/rootedinert.out" 2>&1; then
  cat "$work/rootedinert.out"
  note "selftest failed on a glob matching tracked paths outside the enabled carry classes — inert config is being treated as dead"
fi
grep -q "matches tracked paths but none in the enabled carry classes" "$work/rootedinert.out" \
  || note "inert non-carry-class glob did not report the inert note"

# A SYMLINKED override anchors evidence at its TARGET's repository. The
# symlink lives in a non-repository directory (the common install shape:
# settings symlinked from elsewhere); anchoring at the symlink's own
# directory finds no work tree and silently demotes the run to hermetic
# synthetic probing, where a dead glob manufactures its own match. The
# relative link target also exercises the link-joining branch.
mkdir -p "$work/symlinked/outside"
ln -s ../../rooted/repo/vstack.settings.toml "$work/symlinked/outside/settings.toml"
if ! (cd "$work/symlinked/outside" && REVIEW_GATE_SETTINGS_FILE="$work/symlinked/outside/settings.toml" "$SELFTEST") \
  >"$work/symlinked.out" 2>&1; then
  cat "$work/symlinked.out"
  note "selftest failed under a symlinked settings override"
fi
grep -q "evidence mode: tracked" "$work/symlinked.out" \
  || note "symlinked override did not anchor tracked evidence at the target's repository (hermetic demotion is back)"
grep -q "carry-exclude — 'guides/\*' matches 'guides/intro.md', refusing the carry" "$work/symlinked.out" \
  || note "symlinked override did not probe the target repository's tracked tree"

# An OPTION-LOOKING override (cwd-relative, dash-leading, no slash) names a
# symlink: an unnormalized `readlink -settings` parses the path as an option
# and fails, silently stranding the anchor at the invoking directory —
# hermetic demotion again, by spelling rather than by location.
ln -s "$work/rooted/repo/vstack.settings.toml" "$work/symlinked/outside/-settings"
if ! (cd "$work/symlinked/outside" && REVIEW_GATE_SETTINGS_FILE="-settings" "$SELFTEST") \
  >"$work/symlinkdash.out" 2>&1; then
  cat "$work/symlinkdash.out"
  note "selftest failed under a dash-leading relative symlinked override"
fi
grep -q "evidence mode: tracked" "$work/symlinkdash.out" \
  || note "dash-leading symlinked override did not anchor tracked evidence at the target's repository (readlink option-parse regression)"

# A BROKEN readlink must refuse, never resolve partially: continuing from
# the unresolved link's directory is the same silent hermetic demotion the
# anchor exists to prevent.
mkdir -p "$work/brokenreadlink/bin"
cat >"$work/brokenreadlink/bin/readlink" <<'BROKENREADLINK'
#!/usr/bin/env bash
echo "readlink: planted failure" >&2
exit 1
BROKENREADLINK
chmod +x "$work/brokenreadlink/bin/readlink"
if (cd "$work/symlinked/outside" && PATH="$work/brokenreadlink/bin:$PATH" REVIEW_GATE_SETTINGS_FILE="$work/symlinked/outside/settings.toml" "$SELFTEST") \
  >"$work/brokenreadlink.out" 2>&1; then
  note "selftest passed with a failing readlink on a symlinked override — the unresolved anchor no longer refuses"
else
  grep -q "could not resolve the symlinked settings override" "$work/brokenreadlink.out" \
    || note "broken-readlink failure does not carry the unresolved-override diagnostic"
fi

# A CYCLIC symlink override fails -f (which dereferences the whole chain)
# while very much existing — it must enter resolution via the -L arm and
# refuse on the hop budget, never quietly fall back to the invoking-cwd
# anchor as "file absent".
mkdir -p "$work/cyclic"
ln -s cycle-b.settings.toml "$work/cyclic/cycle-a.settings.toml"
ln -s cycle-a.settings.toml "$work/cyclic/cycle-b.settings.toml"
if (cd "$work/rooted/repo" && REVIEW_GATE_SETTINGS_FILE="$work/cyclic/cycle-a.settings.toml" "$SELFTEST") \
  >"$work/cyclic.out" 2>&1; then
  note "selftest passed with a CYCLIC symlinked override — the unfinishable walk no longer refuses"
else
  grep -q "could not resolve the symlinked settings override" "$work/cyclic.out" \
    || note "cyclic-override failure does not carry the unresolvable-chain diagnostic"
fi

# A BROKEN WORKTREE (a .git file naming a missing gitdir) earns git's
# standard 'not a git repository' text while repository metadata is
# plainly present — that is an unusable evidence base, not a hermetic
# ticket.
mkdir -p "$work/brokengitfile"
printf 'gitdir: /nonexistent/pruned-away/.git/worktrees/gone\n' >"$work/brokengitfile/.git"
cp "$work/excludes/vstack.settings.toml" "$work/brokengitfile/vstack.settings.toml"
if (cd "$work/brokengitfile" && "$SELFTEST") >"$work/brokengitfile.out" 2>&1; then
  note "selftest passed inside a broken worktree (gitfile to a missing gitdir) — the .git-marker guard no longer fires"
else
  grep -q "a .git marker exists" "$work/brokengitfile.out" \
    || note "broken-gitfile failure does not carry the marker diagnostic"
fi

# A repository-probe failure inside a REAL repository must refuse, never
# read as "not a repository": a git shim failing --is-inside-work-tree
# used to silently demote the run to hermetic synthetic probing.
mkdir -p "$work/brokenprobe/bin" "$work/brokenprobe/repo"
cat >"$work/brokenprobe/bin/git" <<BROKENPROBE
#!/usr/bin/env bash
for _a in "\$@"; do
  if [ "\$_a" = "--is-inside-work-tree" ]; then
    echo "fatal: planted probe failure" >&2
    exit 1
  fi
done
exec "$real_git" "\$@"
BROKENPROBE
chmod +x "$work/brokenprobe/bin/git"
(cd "$work/brokenprobe/repo" && "$real_git" init -q .)
cp "$work/excludes/vstack.settings.toml" "$work/brokenprobe/repo/vstack.settings.toml"
if (cd "$work/brokenprobe/repo" && PATH="$work/brokenprobe/bin:$PATH" "$SELFTEST") \
  >"$work/brokenprobe.out" 2>&1; then
  note "selftest passed with a failing repository probe inside a real repo — broken git reads as not-a-repository again"
else
  grep -q "repository probe failed" "$work/brokenprobe.out" \
    || note "broken-probe failure does not carry the repository-probe diagnostic"
fi

# The prophylactic ledger validates BOTH directions. (a) A declaration
# with no matching active exclusion is stale config and FAILs. (b) A
# declaration whose glob has since gained a tracked match FAILs — the
# no-tracked-match assertion no longer holds.
printf 'REVIEW_GATE_CARRY_FORWARD = "docs"\nREVIEW_GATE_CARRY_FORWARD_EXCLUDE = "guides/*"\nREVIEW_GATE_CARRY_FORWARD_EXCLUDE_PROPHYLACTIC = "gudies/*"\n' \
  >"$work/rooted/repo/orphan.settings.toml"
grep -v '^REVIEW_GATE_CARRY_FORWARD = ' "$work/configured/vstack.settings.toml" \
  >>"$work/rooted/repo/orphan.settings.toml"
if (cd "$work/rooted/repo" && REVIEW_GATE_SETTINGS_FILE="$work/rooted/repo/orphan.settings.toml" "$SELFTEST") \
  >"$work/rootedorphan.out" 2>&1; then
  note "selftest passed with a prophylactic declaration naming no active exclusion — the orphan-waiver gate no longer fires"
else
  grep -q "is not an active REVIEW_GATE_CARRY_FORWARD_EXCLUDE entry" "$work/rootedorphan.out" \
    || note "orphan prophylactic declaration does not carry the stale-waiver diagnostic"
fi

printf 'REVIEW_GATE_CARRY_FORWARD = "docs"\nREVIEW_GATE_CARRY_FORWARD_EXCLUDE = "guides/*"\nREVIEW_GATE_CARRY_FORWARD_EXCLUDE_PROPHYLACTIC = "guides/*"\n' \
  >"$work/rooted/repo/falsified.settings.toml"
grep -v '^REVIEW_GATE_CARRY_FORWARD = ' "$work/configured/vstack.settings.toml" \
  >>"$work/rooted/repo/falsified.settings.toml"
if (cd "$work/rooted/repo" && REVIEW_GATE_SETTINGS_FILE="$work/rooted/repo/falsified.settings.toml" "$SELFTEST") \
  >"$work/rootedfalsified.out" 2>&1; then
  note "selftest passed with a prophylactic declaration whose glob matches tracked paths — the falsified-declaration gate no longer fires"
else
  grep -q "no longer holds" "$work/rootedfalsified.out" \
    || note "falsified prophylactic declaration does not carry the no-longer-holds diagnostic"
fi

# A repository with ZERO tracked files is still tracked mode — payload
# emptiness must not demote the run to hermetic synthetic probing, where a
# manufactured path would let a dead glob pass. The banner must say tracked
# and the undeclared glob must FAIL with the no-match diagnostic.
mkdir -p "$work/emptyrepo/repo"
(cd "$work/emptyrepo/repo" && git init -q . \
  && git -c user.email=t@t -c user.name=t commit -qm empty --allow-empty)
grep -v '^REVIEW_GATE_CARRY_FORWARD = ' "$work/configured/vstack.settings.toml" \
  >"$work/emptyrepo/repo/vstack.settings.toml"
printf 'REVIEW_GATE_CARRY_FORWARD = "docs"\nREVIEW_GATE_CARRY_FORWARD_EXCLUDE = "guides/*"\n' \
  >>"$work/emptyrepo/repo/vstack.settings.toml"
if (cd "$work/emptyrepo/repo" && "$SELFTEST") >"$work/emptyrepo.out" 2>&1; then
  note "selftest passed in a zero-tracked-file repository with an undeclared glob — payload emptiness demoted tracked mode to hermetic"
else
  grep -q "evidence mode: tracked" "$work/emptyrepo.out" \
    || note "zero-tracked-file repository did not report tracked evidence mode"
  grep -q "matches NO tracked carry-class" "$work/emptyrepo.out" \
    || note "zero-tracked-file repository did not fail the undeclared glob with the no-match diagnostic"
fi

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
