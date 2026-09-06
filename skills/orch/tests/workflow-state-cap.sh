#!/usr/bin/env bash
# `workflow-state cap <SETTING> [--issue <id>]`: the one reader of a round cap.
# The rereview_panel guard and every workflow that reads a cap come through
# this table, so its verdict must agree with the write it gates, exactly, at
# the boundary; the roster of caps is derived from the table, never spelled;
# and no script or workflow resolves a cap outside it. Split from
# workflow-state-cycle-cap.sh, which owns the rereview_panel write itself.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

WS="$REPO_ROOT/skills/orch/scripts/workflow-state"
PANEL='{"agents": ["rev-a"], "reason": "test"}'

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

# --- `cap`: the one reader of a round cap ----------------------------------
# The guard above and every workflow that reads a cap come through this table,
# so its verdict must agree with the write it gates, exactly, at the boundary.
echo
echo "--- workflow-state cap ---"

cd_sd="$TMP_ROOT/cap-state"
"$WS" --state-dir "$cd_sd" init KEN-CAP --worktree "$REPO_ROOT" --branch ken-cap >/dev/null

got="$("$WS" --state-dir "$cd_sd" cap REVIEW_MAX_CYCLES)"
[[ "$got" == "4" ]] && ok "bare cap prints the resolved limit" || bad "bare cap prints the resolved limit" "got=$got"

got="$("$WS" --state-dir "$cd_sd" cap REVIEW_MAX_CYCLES --issue KEN-CAP)"
[[ "$got" == "below 0/4" ]] && ok "a fresh issue is below the re-review cap" \
  || bad "a fresh issue is below the re-review cap" "got=$got"

# Walk the counter to the exact boundary and read both readers at each step:
# the verdict flips on the same count the rereview_panel write starts refusing.
flip_verdict=""
flip_write=""
for n in 0 1 2 3 4 5; do
  "$WS" --state-dir "$cd_sd" update KEN-CAP ".rereview_cycles = $n" >/dev/null
  verdict="$("$WS" --state-dir "$cd_sd" cap REVIEW_MAX_CYCLES --issue KEN-CAP)"
  if [[ -z "$flip_verdict" && "$verdict" == at-cap* ]]; then flip_verdict="$n"; fi
  if "$WS" --state-dir "$cd_sd" set KEN-CAP rereview_panel "$PANEL" >/dev/null 2>&1; then
    "$WS" --state-dir "$cd_sd" update KEN-CAP ".rereview_cycles = $n" >/dev/null
  elif [[ -z "$flip_write" ]]; then
    flip_write="$n"
  fi
done
[[ "$flip_verdict" == "4" ]] && ok "the cap verdict flips to at-cap at 4" \
  || bad "the cap verdict flips to at-cap at 4" "flipped at=$flip_verdict"
[[ "$flip_verdict" == "$flip_write" ]] \
  && ok "the cap verdict and the rereview_panel refusal flip on the same count" \
  || bad "the cap verdict and the rereview_panel refusal flip on the same count" \
     "verdict=$flip_verdict write=$flip_write"

# --- the external round cap's own row --------------------------------------
# The comment loop and submit-pr read REVIEW_MAX_EXTERNAL_ROUNDS through the
# same table, and `review-external-rounds-cap.test.sh` would prove its row
# from its own scratch repos. This is where that proof lives now. This repo's
# `kendex.settings.toml` names every cap at the table's own number, so a bare
# read here would hold whatever default the table carried. Where a default is
# proved below it resolves from this settings-free checkout with the setting
# stripped from the process environment, the two layers orch-env ranks above
# the table, leaving only the table to answer.
no_settings="$TMP_ROOT/no-settings"
git init -q "$no_settings"
got="$(cd "$no_settings" && env -u REVIEW_MAX_EXTERNAL_ROUNDS "$WS" --state-dir "$cd_sd" cap REVIEW_MAX_EXTERNAL_ROUNDS)"
[[ "$got" == "4" ]] && ok "REVIEW_MAX_EXTERNAL_ROUNDS defaults to 4 through the table" \
  || bad "REVIEW_MAX_EXTERNAL_ROUNDS defaults to 4 through the table" "got=$got"

# Two rows, not one: the external cap moving must leave the re-review cap where
# the table put it, or the two knobs are one.
got="$(cd "$no_settings" && REVIEW_MAX_EXTERNAL_ROUNDS=9 env -u REVIEW_MAX_CYCLES "$WS" --state-dir "$cd_sd" cap REVIEW_MAX_CYCLES)"
[[ "$got" == "4" ]] && ok "moving the external cap leaves REVIEW_MAX_CYCLES alone" \
  || bad "moving the external cap leaves REVIEW_MAX_CYCLES alone" "got=$got"

# Its row names `pr_comment_review.iterations`, so `--issue` counts the triage
# passes rather than the re-review entries the row above it counts.
"$WS" --state-dir "$cd_sd" update KEN-CAP '.pr_comment_review.iterations = 3' >/dev/null
got="$("$WS" --state-dir "$cd_sd" cap REVIEW_MAX_EXTERNAL_ROUNDS --issue KEN-CAP)"
[[ "$got" == "below 3/4" ]] && ok "the external cap counts pr_comment_review.iterations" \
  || bad "the external cap counts pr_comment_review.iterations" "got=$got"
"$WS" --state-dir "$cd_sd" update KEN-CAP '.pr_comment_review.iterations = 4' >/dev/null
got="$("$WS" --state-dir "$cd_sd" cap REVIEW_MAX_EXTERNAL_ROUNDS --issue KEN-CAP)"
[[ "$got" == "at-cap 4/4" ]] && ok "the external cap reads at-cap once the budget is spent" \
  || bad "the external cap reads at-cap once the budget is spent" "got=$got"

# One table, one default: a setting the table does not hold is refused rather
# than silently defaulted, and a state-less cap refuses --issue.
rc=0; "$WS" --state-dir "$cd_sd" cap NOT_A_CAP >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 2 ]] && ok "an unknown cap name is refused" || bad "an unknown cap name is refused" "rc=$rc"
rc=0; "$WS" --state-dir "$cd_sd" cap CI_FIX_MAX_CYCLES --issue KEN-CAP >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 2 ]] && ok "a cap with no state field refuses --issue" \
  || bad "a cap with no state field refuses --issue" "rc=$rc"
got="$(env -u CI_FIX_MAX_CYCLES "$WS" --state-dir "$cd_sd" cap CI_FIX_MAX_CYCLES --count 5)"
[[ "$got" == "below 5/6" ]] && ok "CI_FIX_MAX_CYCLES defaults to 6 through the table" \
  || bad "CI_FIX_MAX_CYCLES defaults to 6 through the table" "got=$got"

# The assertion above ran where this repo's own [env] names CI_FIX_MAX_CYCLES at
# the table's number, so it would have held whatever default the table carried.
# The settings-free checkout is what proves the number comes from the table --
# and `env -u`, because orch-env ranks the process environment above the file,
# so an exported CI_FIX_MAX_CYCLES would answer over both.
got="$(cd "$no_settings" && env -u CI_FIX_MAX_CYCLES "$WS" --state-dir "$cd_sd" cap CI_FIX_MAX_CYCLES --count 5)"
[[ "$got" == "below 5/6" ]] && ok "the table's default is what resolves where no setting overrides it" \
  || bad "the table's default is what resolves where no setting overrides it" "got=$got"

# The roster is derived, never spelled. The refusal and the help text once held
# their own copies of it beside the two case arms that resolved a cap, so a cap
# included in one place was missing from the others. Both must now name exactly the
# settings the table resolves.
roster_of() { tr ',' '\n' <<<"$1" | tr -d ' ' | grep -v '^$' | sort; }
refusal_roster="$(roster_of "$("$WS" --state-dir "$cd_sd" cap NOT_A_CAP 2>&1 >/dev/null | sed 's/.*(known: //; s/)$//')")"
help_roster="$("$WS" help | sed -n 's/^ *\([A-Z][A-Z_]*\) (.*/\1/p' | sort)"
[[ -n "$refusal_roster" && "$refusal_roster" == "$help_roster" ]] \
  && ok "the refusal and the help name the same caps" \
  || bad "the refusal and the help name the same caps" "refusal=[$refusal_roster] help=[$help_roster]"
missing=""
while IFS= read -r setting; do
  [[ -n "$setting" ]] || continue
  "$WS" --state-dir "$cd_sd" cap "$setting" >/dev/null 2>&1 || missing="$missing $setting"
done <<<"$refusal_roster"
[[ -z "$missing" ]] && ok "every cap the roster names resolves through the table" \
  || bad "every cap the roster names resolves through the table" "unresolved:$missing"

# The default lives in the table alone: no reader may carry its own copy.
# The scan covers the WORKFLOWS as well as the scripts, and the quote before
# the setting name is optional, because a workflow spells the same read as a
# bare command line -- `.agents/skills/orch/scripts/orch-env CI_FIX_MAX_CYCLES
# 6`. Scripts-and-quotes-only, this check watched the two sites that already
# had rule pins and none of the four this branch rewrote in the workflows,
# where the two-spellings-disagree shape it exists to close would have gone
# back in unseen.
CAP_STRAY_RE='orch-env"? *(CI_FIX_MAX_CYCLES|REVIEW_MAX)'
cap_strays() { grep -rnE "$CAP_STRAY_RE" "$@" 2>/dev/null || true; }
stray="$(cap_strays "$REPO_ROOT/skills/orch/scripts" "$REPO_ROOT/skills/orch/workflows")"
[[ -z "$stray" ]] && ok "no orch script or workflow resolves a round cap outside the table" \
  || bad "no orch script or workflow resolves a round cap outside the table" "$stray"
# Planted, in both spellings: a reader that went back to pairing orch-env with
# its own default. The workflow one is the control for the widened scan --
# under the old scripts-only root it read clean.
CTRL_DIR="$TMP_ROOT/cap-stray-scripts"
CTRL_WF="$TMP_ROOT/cap-stray-workflows"
mkdir -p "$CTRL_DIR" "$CTRL_WF"
printf 'max=$("$SCRIPT_DIR/orch-env" CI_FIX_MAX_CYCLES 6)\n' > "$CTRL_DIR/watcher"
printf '.agents/skills/orch/scripts/orch-env CI_FIX_MAX_CYCLES 6\n' > "$CTRL_WF/merge-pr.md"
[[ -n "$(cap_strays "$CTRL_DIR")" ]] && ok "the stray check flags a script carrying its own cap default" \
  || bad "the stray check flags a script carrying its own cap default"
[[ -n "$(cap_strays "$CTRL_WF")" ]] && ok "the stray check flags a workflow carrying its own cap default" \
  || bad "the stray check flags a workflow carrying its own cap default"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
