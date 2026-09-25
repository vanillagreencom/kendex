#!/usr/bin/env bash
# `workflow-state prune`: the retention that
# ../schemas/workflow-state.md § Recording policy states, on a fixture fleet. Past ORCH_RECORD_RETENTION_DAYS a closed lane's
# files, an old directive, an old handoff archive and an old progress report
# go, with the fleet_log rows and done lane records past the window. A live
# lane's files, a --keep path and the named keep list stay whatever their age.
# Everything removed is in the archive `kept=` names first, and a prune whose
# archive cannot be written removes nothing.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)"

WS="$REPO_ROOT/skills/orch/scripts/workflow-state"
source "$REPO_ROOT/skills/orch/scripts/lib/date-ladder.sh"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

echo
echo "--- workflow-state prune ---"

now="$(date -u +%s)"
old_at="$(from_epoch "$((now - 3 * 86400))" '%Y-%m-%dT%H:%M:%SZ')"
old_touch="$(from_epoch "$((now - 3 * 86400))" '%Y%m%d%H%M' '')"
fresh_at="$(from_epoch "$now" '%Y-%m-%dT%H:%M:%SZ')"

# One project per case, outside Git, so its root, its progress directory and
# its archive name are the sandbox's own; the retention is two days and every
# old fixture is three days old.
build() { # DIR
  local p="$1" sd="$1/tmp"
  mkdir -p "$p"
  (cd "$p" && "$WS" init oversee >/dev/null)
  jq --arg old "$old_at" --arg fresh "$fresh_at" '
    .lanes = [{item: "KEN-1", status: "running", launched_at: $old},
              {item: "KEN-2", status: "done", launched_at: $old}]
    | .fleet_log = [{at: $old, kind: "ruling", item: "KEN-2", text: "old"},
                    {at: $fresh, kind: "ruling", item: "KEN-1", text: "fresh"}]' \
    "$sd/workflow-state-oversee.json" > "$sd/next.json"
  mv "$sd/next.json" "$sd/workflow-state-oversee.json"
  mkdir -p "$sd/lane-mail/KEN-1" "$sd/lane-mail/KEN-2" "$sd/lane-mail/overseer" \
    "$sd/handoffs" "$sd/progress-reports" "$sd/waiter.run"
  for f in lane-mail/KEN-1/to-lane.jsonl lane-mail/KEN-2/to-lane.jsonl lane-mail/overseer/to-lane.jsonl \
    workflow-state-KEN-1.json workflow-state-KEN-2.json lane-status-KEN-1.md directive.md \
    handoffs/OVERSEER-HANDOFF.md handoffs/session-1.md progress-reports/01-01-00-00.md \
    waiter.run/watch.log; do
    printf 'x\n' > "$sd/$f"
  done
  find "$sd" -mindepth 1 -exec touch -t "$old_touch" {} +
  printf 'x\n' > "$sd/fresh.md"
  printf 'x\n' > "$sd/progress-reports/fresh.md"
}

prune() { # DIR [ARGS...]
  local p="$1"
  shift
  (cd "$p" && ORCH_RECORD_RETENTION_DAYS=2 FLEET_DIR="$p/fleet" "$WS" prune "$@")
}

p="$TMP_ROOT/main"
build "$p"
sd="$p/tmp"
rc=0
prune "$p" --keep tmp/waiter.run > "$TMP_ROOT/main.out" 2>"$TMP_ROOT/main.err" || rc=$?
[[ "$rc" -eq 0 ]] && ok "prune exits 0" || bad "prune exits 0" "rc=$rc err=$(cat "$TMP_ROOT/main.err")"

# Every path the policy removes, and every path it keeps, one row each.
while IFS='|' read -r want path label; do
  if [[ -e "$sd/$path" ]]; then got=kept; else got=removed; fi
  [[ "$got" == "$want" ]] \
  && ok "$label is $want" \
  || bad "$label is $want" "path=$path got=$got"
done <<'ROWS'
removed|directive.md|a three-day-old directive
removed|workflow-state-KEN-2.json|a closed lane's workflow state
removed|lane-mail/KEN-2|a closed lane's mailbox
removed|handoffs/session-1.md|an old handoff archive
removed|progress-reports/01-01-00-00.md|an old progress report
kept|workflow-state-KEN-1.json|a running lane's workflow state
kept|lane-mail/KEN-1/to-lane.jsonl|a running lane's mailbox
kept|lane-status-KEN-1.md|a running lane's status file
kept|lane-mail/overseer/to-lane.jsonl|the overseer's own mailbox
kept|workflow-state-oversee.json|the fleet state
kept|handoffs/OVERSEER-HANDOFF.md|the overseer handoff file
kept|waiter.run/watch.log|the --keep watch log
kept|fresh.md|a file inside the retention
kept|progress-reports/fresh.md|a progress report inside the retention
ROWS

got="$(jq -c '[.fleet_log[].text, (.lanes[] | .item)]' "$sd/workflow-state-oversee.json")"
[[ "$got" == '["fresh","KEN-1"]' ]] \
  && ok "the old fleet_log row and the done lane record leave the state" \
  || bad "the old fleet_log row and the done lane record leave the state" "got=$got"

count="$(grep '^pruned fleet_log=' "$TMP_ROOT/main.out" || true)"
[[ "$count" == "pruned fleet_log=1 lanes=1 progress_reports=1 paths=5" ]] \
  && ok "the count line names each record removed" \
  || bad "the count line names each record removed" "got=$count"

archive="$(sed -n 's/^kept=//p' "$TMP_ROOT/main.out")"
[[ "$archive" == "$p/fleet/archive/main/oversee/prune-"*.tgz && -s "$archive" ]] \
  && ok "kept= names the archive written under the fleet archive" \
  || bad "kept= names the archive written under the fleet archive" "archive=$archive"

listing="$(tar -tzf "$archive" 2>/dev/null || true)"
missing=""
for path in directive.md workflow-state-KEN-2.json lane-mail/KEN-2/to-lane.jsonl handoffs/session-1.md \
  progress-reports/01-01-00-00.md; do
  grep -qxF -- "${sd#/}/$path" <<<"$listing" || missing="$missing $path"
done
[[ -z "$missing" ]] \
  && ok "the archive holds every removed path" \
  || bad "the archive holds every removed path" "missing:$missing"
mkdir -p "$TMP_ROOT/unpacked"
tar -xzf "$archive" -C "$TMP_ROOT/unpacked" 2>/dev/null || true
records="$(find "$TMP_ROOT/unpacked" -name records.json)"
got="$(jq -c '[.fleet_log[].text, (.lanes[] | .item)]' "$records" 2>/dev/null || true)"
[[ "$got" == '["old","KEN-2"]' ]] \
  && ok "the archive holds the removed fleet_log row and lane record" \
  || bad "the archive holds the removed fleet_log row and lane record" "got=$got"

# A prune with nothing past the window archives nothing.
rc=0
out="$(prune "$p" --keep tmp/waiter.run 2>&1)" || rc=$?
[[ "$rc" -eq 0 && "$(tail -n 1 <<<"$out")" == "kept=none" ]] \
  && ok "a prune with nothing to remove prints kept=none" \
  || bad "a prune with nothing to remove prints kept=none" "rc=$rc out=$out"

# No fleet state, no lane records to tell live from closed: refused.
mkdir -p "$TMP_ROOT/bare/tmp"
rc=0
(cd "$TMP_ROOT/bare" && "$WS" prune) >/dev/null 2>"$TMP_ROOT/bare.err" || rc=$?
key="$(head -n 1 "$TMP_ROOT/bare.err")"
[[ "$rc" -eq 1 && "$key" == "workflow-state: state-missing state-file=$TMP_ROOT/bare/tmp/workflow-state-oversee.json" ]] \
  && ok "a prune with no fleet state is refused as state-missing" \
  || bad "a prune with no fleet state is refused as state-missing" "rc=$rc key=$key"

# An archive that cannot be written removes nothing: a tar that fails, and an
# archive root that is a file.
FAIL_BIN="$TMP_ROOT/fail-bin"
mkdir -p "$FAIL_BIN"
printf '#!/bin/sh\nexit 1\n' > "$FAIL_BIN/tar"
chmod +x "$FAIL_BIN/tar"
unwritable() { # DIR MODE
  case "$2" in
    tar) (cd "$1" && PATH="$FAIL_BIN:$PATH" ORCH_RECORD_RETENTION_DAYS=2 FLEET_DIR="$1/fleet" "$WS" prune) ;;
    root) printf 'x\n' > "$1/fleet-file"
          (cd "$1" && ORCH_RECORD_RETENTION_DAYS=2 FLEET_DIR="$1/fleet-file" "$WS" prune) ;;
  esac
}
while IFS='|' read -r mode label; do
  fp="$TMP_ROOT/fail-$mode"
  build "$fp"
  before="$(cd "$fp/tmp" && find . | sort)"
  state_before="$(cat "$fp/tmp/workflow-state-oversee.json")"
  rc=0
  unwritable "$fp" "$mode" >/dev/null 2>"$fp.err" || rc=$?
  key="$(head -n 1 "$fp.err")"
  after="$(cd "$fp/tmp" && find . | sort)"
  [[ "$rc" -eq 1 && "$key" == "workflow-state: prune-archive-failed path="* \
     && "$after" == "$before" && "$(cat "$fp/tmp/workflow-state-oversee.json")" == "$state_before" ]] \
  && ok "$label is refused as prune-archive-failed and removes nothing" \
  || bad "$label is refused as prune-archive-failed and removes nothing" "rc=$rc key=$key"
done <<'ROWS'
tar|an archive tar cannot write
root|an archive root that is a file
ROWS

MUTANT_DIR="$TMP_ROOT/mutant"
mkdir -p "$MUTANT_DIR"
cp -R "$REPO_ROOT/skills/orch/scripts/lib" "$MUTANT_DIR/lib"
cp "$REPO_ROOT/skills/orch/scripts/orch-env" "$REPO_ROOT/skills/orch/scripts/git-context" "$MUTANT_DIR/"
mutant() { # NAME ANCHOR REPLACEMENT
  [[ "$(grep -Fc -- "$2" "$WS")" == "1" ]] \
  && ok "the $1 control finds its anchor" \
  || bad "the $1 control finds its anchor"
  awk -v a="$2" -v r="$3" 'index($0, a) { sub(/[^ ].*/, ""); print $0 r; next } { print }' "$WS" > "$MUTANT_DIR/$1"
}

# Planted: the live-lane match removed. The running lane's mailbox and
# workflow state then age out like a closed lane's.
mutant no-live '[[ ! "${unit##*/}" =~ $re ]] || kept_by=live' ':'
mp="$TMP_ROOT/m-live"
build "$mp"
(cd "$mp" && ORCH_RECORD_RETENTION_DAYS=2 FLEET_DIR="$mp/fleet" bash "$MUTANT_DIR/no-live" prune \
  --keep tmp/waiter.run) >/dev/null 2>&1 || true
[[ ! -e "$mp/tmp/lane-mail/KEN-1" ]] \
  && ok "control: without the live-lane match a running lane's mailbox is pruned" \
  || bad "control: without the live-lane match a running lane's mailbox is pruned"

# Planted: the --keep match removed. The current watch log then ages out.
mutant no-keep '[[ "$unit" != "$keep" && "$keep" != "$unit"/* ]] || kept_by=keep' ':'
mp="$TMP_ROOT/m-keep"
build "$mp"
(cd "$mp" && ORCH_RECORD_RETENTION_DAYS=2 FLEET_DIR="$mp/fleet" bash "$MUTANT_DIR/no-keep" prune \
  --keep tmp/waiter.run) >/dev/null 2>&1 || true
[[ ! -e "$mp/tmp/waiter.run" ]] \
  && ok "control: without the --keep match the kept watch log is pruned" \
  || bad "control: without the --keep match the kept watch log is pruned"

# Planted: the archive's failure no longer stops the prune. A failed tar then
# leaves the removed paths in no archive at all.
mutant archive-ignored '&& tar -czf "$stage.tgz" -C / -T "$stage/paths" 2>"$stage/tar.err"; }; then' \
  '&& { tar -czf "$stage.tgz" -C / -T "$stage/paths" || true; }; }; then'
mp="$TMP_ROOT/m-archive"
build "$mp"
(cd "$mp" && PATH="$FAIL_BIN:$PATH" ORCH_RECORD_RETENTION_DAYS=2 FLEET_DIR="$mp/fleet" \
  bash "$MUTANT_DIR/archive-ignored" prune) >/dev/null 2>&1 || true
[[ ! -e "$mp/tmp/directive.md" ]] \
  && ok "control: without the archive refusal a failed archive still removes the directive" \
  || bad "control: without the archive refusal a failed archive still removes the directive"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
