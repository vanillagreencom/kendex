#!/usr/bin/env bash
# Regression lint for vstack#818 (harness-specific claims stated as universal).
#
# The orch/dev skills run on Claude Code, Codex, OpenCode, and Pi, and they
# already carry a labeling pattern for per-harness behavior: the
# `> If you are running in **Claude Code / Codex / OpenCode / Pi**:` blocks in
# orch SKILL.md, and inline-labeled bullets like `**Task-based** (Claude Code)`.
# vstack#818's audit found harness-specific instructions sitting OUTSIDE that
# pattern — an `AskUserQuestion` reference in a universal section, `Explore`
# sub-agents named in the every-harness bootstrap, a `sleep`-poll loop the
# skill's own Codex block says the `approval=never` classifier rejects, and the
# Claude-Code Bash-tool `~10 min` cap presented as a property of every harness.
#
# This lint asserts: every line in the orch/dev docs that carries a known
# harness-specific TOKEN must be harness-LABELED. A token line is labeled when a
# harness name appears anywhere in its block context:
#   - the token line itself, or
#   - the contiguous non-blank run (paragraph / blockquote / list item) it
#     belongs to, or
#   - for a token inside a fenced code block: the fence plus the paragraph that
#     introduces it (blank lines between prose and fence are skipped), or
#   - the nearest preceding Markdown heading.
#
# That is deliberately permissive about WHERE the label sits (inline, blockquote
# lead-in, or section heading all count) and strict only about it existing, so
# ordinary edits near a labeled block do not trip it. It does not check that the
# label names the *owning* harness — a Codex block may legitimately say "there
# is no ~10-min tool cap".
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

# Harness-specific tokens. Each is a behavioral claim or tool/API name that is
# true on one harness and false or absent on the others.
#   AskUserQuestion / SendMessage / run_in_background  — Claude Code tool names
#   Explore sub-agent(s)                               — Claude Code agent type
#   ~10 min / ~10-min                                  — Claude Code Bash cap
#   sleep N                                            — poll shape Codex rejects
#   bg_task                                            — Pi
#   send_input                                         — Codex
TOKEN_RE='AskUserQuestion|SendMessage|run_in_background|Explore sub-agent|~10 ?-?min|sleep [0-9]|bg_task|send_input'

# Harness names that count as a label. `Pi` is matched case-sensitively with
# word boundaries so it cannot be satisfied by an unrelated capitalized word.
HARNESS_RE='Claude Code|Codex|OpenCode|(^|[^[:alnum:]])Pi([^[:alnum:]]|$)|pi-agents-tmux'

# scan_labels <file>
# Emits one "file:line: ..." line per token line whose block context carries no
# harness name.
scan_labels() {
  awk -v f="$1" -v tokre="$TOKEN_RE" -v harnre="$HARNESS_RE" '
    { line[NR] = $0 }
    END {
      n = NR
      # Pass 1: mark fenced-code regions and record each fence opener.
      infence = 0
      for (i = 1; i <= n; i++) {
        if (line[i] ~ /^[[:space:]]*```/) {
          if (infence == 0) { infence = 1; opener = i; fence[i] = 1; open_of[i] = i }
          else { infence = 0; fence[i] = 1; open_of[i] = opener }
          continue
        }
        fence[i] = infence
        if (infence) open_of[i] = opener
      }

      for (i = 1; i <= n; i++) {
        if (line[i] !~ tokre) continue
        # A fenced closer/opener line itself carries no instruction text.
        if (line[i] ~ /^[[:space:]]*```/) continue

        # --- establish the block context [lo, hi] ---------------------------
        if (fence[i]) {
          lo = open_of[i]
          hi = lo
          while (hi < n && !(hi > lo && line[hi] ~ /^[[:space:]]*```/)) hi++
          # Walk back past blank lines to the paragraph introducing the fence.
          j = lo - 1
          while (j >= 1 && line[j] ~ /^[[:space:]]*$/) j--
          while (j >= 1 && line[j] !~ /^[[:space:]]*$/ && line[j] !~ /^[[:space:]]*```/) j--
          lo = j + 1
        } else {
          lo = i; hi = i
          while (lo > 1 && line[lo - 1] !~ /^[[:space:]]*$/ && line[lo - 1] !~ /^[[:space:]]*```/) lo--
          while (hi < n && line[hi + 1] !~ /^[[:space:]]*$/ && line[hi + 1] !~ /^[[:space:]]*```/) hi++
        }

        labeled = 0
        for (k = lo; k <= hi; k++) if (line[k] ~ harnre) { labeled = 1; break }

        # Nearest preceding heading also labels the line.
        if (!labeled) {
          for (k = i; k >= 1; k--) {
            if (line[k] ~ /^#{1,6} /) { if (line[k] ~ harnre) labeled = 1; break }
          }
        }

        if (!labeled) {
          t = line[i]
          sub(/^[[:space:]]+/, "", t)
          if (length(t) > 110) t = substr(t, 1, 110) "..."
          printf "%s:%d: harness-specific token outside a labeled block: %s\n", f, i, t
        }
      }
    }
  ' "$1"
}

echo "=== orch/dev harness-label lint (vstack#818) ==="

# --- Part a: the real orch and dev docs must be clean ----------------------
DOCS=(
  "$SKILLS_ROOT/orch/SKILL.md"
  "$SKILLS_ROOT/orch/DEVELOPMENT.md"
  "$SKILLS_ROOT"/orch/workflows/*.md
  "$SKILLS_ROOT"/orch/references/*.md
  "$SKILLS_ROOT"/orch/schemas/*.md
  "$SKILLS_ROOT/dev/SKILL.md"
  "$SKILLS_ROOT"/dev/workflows/*.md
)
offenders=""
for doc in "${DOCS[@]}"; do
  out="$(scan_labels "$doc")"
  [[ -n "$out" ]] && offenders+="$out"$'\n'
done
if [[ -z "$offenders" ]]; then
  pass "every harness-specific token in orch/dev docs sits in a labeled block"
else
  fail "harness-specific tokens stated as universal:"
  printf '%s' "$offenders" | sed 's/^/          /'
fi

# --- Part b: the lint has teeth --------------------------------------------

# inject <descriptor> <line...> → prints scratch-file path.
# Appends the given lines to a scratch copy of a real, now-clean workflow doc.
# The base doc has zero offenders, so any offender reported comes from the
# injected text. A trailing "## Plain" heading isolates the injection from the
# base doc's own (possibly labeled) last heading.
inject() {
  local scratch="$TMP_ROOT/inject-$1.md"
  cp "$SKILLS_ROOT/orch/workflows/dev-start.md" "$scratch"
  shift
  printf '\n## Plain Section\n\n' >> "$scratch"
  printf '%s\n' "$@" >> "$scratch"
  printf '%s' "$scratch"
}

# b.1 — the audit's own shapes ARE flagged when unlabeled.
if [[ -n "$(scan_labels "$(inject ask 'Ask the user with the AskUserQuestion tool.')")" ]]; then
  pass "lint flags an unlabeled AskUserQuestion instruction"
else
  fail "lint MISSED an unlabeled AskUserQuestion instruction (no teeth)"
fi

if [[ -n "$(scan_labels "$(inject explore 'You may use Explore sub-agents for codebase search.')")" ]]; then
  pass "lint flags an unlabeled Explore sub-agent instruction"
else
  fail "lint MISSED an unlabeled Explore sub-agent instruction (no teeth)"
fi

if [[ -n "$(scan_labels "$(inject cap 'A run exceeding the tool timeout (~10 min) must be backgrounded.')")" ]]; then
  pass "lint flags an unlabeled ~10 min tool-cap claim"
else
  fail "lint MISSED an unlabeled ~10 min tool-cap claim (no teeth)"
fi

if [[ -n "$(scan_labels "$(inject bg 'Start the command with run_in_background and end the turn.')")" ]]; then
  pass "lint flags an unlabeled run_in_background instruction"
else
  fail "lint MISSED an unlabeled run_in_background instruction (no teeth)"
fi

# b.2 — an unlabeled sleep-poll shape inside a fenced block IS flagged.
if [[ -n "$(scan_labels "$(inject sleepfence 'Poll until the queue clears:' '' '```bash' 'sleep 30' '```')")" ]]; then
  pass "lint flags an unlabeled sleep-poll shape inside a fenced block"
else
  fail "lint MISSED an unlabeled sleep-poll shape in a fence (no teeth)"
fi

# b.3 — the same shape IS accepted when the introducing paragraph names the
# harness (the fix shape used in merge-pr.md § 3).
if [[ -z "$(scan_labels "$(inject sleeplabeled 'In Claude Code, back off before re-checking:' '' '```bash' 'sleep 30' '```')")" ]]; then
  pass "lint accepts a fenced sleep whose introducing paragraph names a harness"
else
  fail "lint false-flagged a fenced sleep introduced by a labeled paragraph"
fi

# b.4 — inline labeling on the same line is accepted.
if [[ -z "$(scan_labels "$(inject inline 'In Claude Code, ask the user with the AskUserQuestion tool.')")" ]]; then
  pass "lint accepts an inline harness label on the token line"
else
  fail "lint false-flagged an inline-labeled token line"
fi

# b.5 — a labeled blockquote lead-in labels its continuation lines.
if [[ -z "$(scan_labels "$(inject quote '> If you are running in **Claude Code**: background the run.' '> Start it with run_in_background and end your turn.')")" ]]; then
  pass "lint accepts a token inside a labeled blockquote run"
else
  fail "lint false-flagged a token inside a labeled blockquote"
fi

# b.6 — a harness-labeled heading labels the section under it.
if [[ -z "$(scan_labels "$(inject heading '### Mitigations (Claude Code teams)' '' '| Behavior | Mitigation |' '|---|---|' '| Idle wake | Use SendMessage once |')")" ]]; then
  pass "lint accepts a table row under a harness-labeled heading"
else
  fail "lint false-flagged a row under a harness-labeled heading"
fi

# b.7 — scoping check: a harness name elsewhere in the file does NOT launder an
# unlabeled token in an unrelated section.
if [[ -n "$(scan_labels "$(inject scoping 'Background the run with run_in_background.')")" ]]; then
  pass "lint does not accept a harness label from an unrelated section"
else
  fail "lint laundered an unlabeled token via a distant harness mention"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
