#!/usr/bin/env bash
# Tests for the CI ci class job set queue contract.
set -euo pipefail

# A suite running from inside a git hook inherits GIT_DIR, GIT_COMMON_DIR,
# GIT_WORK_TREE and GIT_INDEX_FILE, which would resolve ROOT to the hook's
# repository instead of this one.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ci-job-set-world.sh
. "$TEST_DIR/lib/ci-job-set-world.sh"

source "$TEST_DIR/lib/ci-job-set-case.sh"

# --- 1c. The queue's macOS legs ---------------------------------------------
# queue_macos_shards per row; the lane-source row above holds it over a
# proof that stood every runner down.
# WORLD (tree or fixture)|CLASS|PATHS (blank-separated)|MACOS
queue_table() {
  cat <<ROWS
tree|micro|skills/orch/SKILL.md .agents/skills/orch/SKILL.md|false
tree|micro|skills/orch/scripts/open-terminal|true
tree|standard|skills/orch/SKILL.md|true
tree|render|.agents/skills/orch/SKILL.md|false
fixture|micro|skills/price-handling/scripts/x|true
fixture|micro|$PI|false
fixture|micro|.claude/hooks/lane-mail-check|true
fixture|micro|$PRICE $PI|true
ROWS
}
queue_selection() { # EVENT WORLD CLASS PATHS [COPY]
  local world="$ROOT"
  [ "$2" = tree ] || world="$SEL_WORLD"
  SELECT_IN="$world" SELECT_WITH="${5:-$JOB_SET}" SELECT_EVENT="$1" \
    selection "$3" false "$(printf '%s\n' $4)"
}
queue_of() { # EVENT WORLD CLASS PATHS [COPY] — the queue_macos_shards value, or the refusal key
  local got
  got="$(queue_selection "$@")"
  case "$got" in
    exit=*) printf '%s' "$got" ;;
    *) field queue_macos_shards <<<"$got" ;;
  esac
}
queue_rows=0
while IFS='|' read -r world class paths macos; do
  for event in pull_request merge_group; do
    queue_rows=$((queue_rows + 1))
    got="$(queue_selection "$event" "$world" "$class" "$paths")"
    expected='[]'
    [ "$macos" = false ] || expected="$(macos_shards "$(field shards <<<"$got")")"
    check "queue legs: $class on $event over '$paths'" "$expected" "$(field queue_macos_shards <<<"$got")"
  done
done < <(queue_table)
[ "$queue_rows" -ge 9 ] || { echo "the queue table read $queue_rows rows" >&2; exit 1; }
# EDIT@PATHS: a copy with that rule removed must fail the row over PATHS.
# A refusal is a broken copy, never a reddened row.
while IFS='@' read -r edit paths; do
  sed "$edit" "$JOB_SET" >"$TMP/rule/tools/ci-job-set"
  chmod +x "$TMP/rule/tools/ci-job-set"
  changed="$(diff "$JOB_SET" "$TMP/rule/tools/ci-job-set" | grep -c '^>' || :)"
  if [ "$changed" != 1 ]; then
    bad "control: the edit changed $changed lines of a ci-job-set copy, not one: $edit"
    continue
  fi
  line="$(queue_table | grep -F -- "|$paths|")" || { echo "no queue row over $paths" >&2; exit 1; }
  IFS='|' read -r world class _ macos <<<"$line"
  for event in pull_request merge_group; do
    base="$(queue_selection "$event" "$world" "$class" "$paths")"
    expected='[]'
    [ "$macos" = false ] || expected="$(macos_shards "$(field shards <<<"$base")")"
    got="$(queue_of "$event" "$world" "$class" "$paths" "$TMP/rule/tools/ci-job-set")"
    case "$got" in
      exit=*) bad "control: $edit broke the ci-job-set copy over $paths ($got)" ;;
      *) [ "$got" != "$expected" ] && ok "control: $edit fails the queue row on $event over $paths" ||
        bad "control: $edit leaves the queue row green on $event over $paths" ;;
    esac
  done
done <<'CONTROLS'
s/^if \[ "\$(sel_get "\$now" macos)" = true \]; then$/if true; then/@skills/orch/SKILL.md .agents/skills/orch/SKILL.md
/queue=/s/^    case "\$now_shards" in \*"\\"\$shard\\""\*) \(.*\) ;; esac$/    \1/@skills/price-handling/scripts/x
/queue=/s/^    case "\$now_shards" in \*"\\"\$shard\\""\*)/    case "\$now_shards" in *"\\"\$shard"*)/@.claude/hooks/lane-mail-check
s/^    case " \$LINUX_ONLY_SHARDS " in \*" \$shard "\*) continue ;; esac$/    :/@skills/price-handling/scripts/x pi-extensions/pi-demo/src/x.ts
CONTROLS

# --- 1d. The queue route ---------------------------------------------------
# kendex.settings.toml names this script and its queue_macos_shards line as
# harness-ci's HARNESS_CI_QUEUE_SELECTOR, so a change whose selection names a
# queue macOS shard reads queue-only and merges through the queue, and one
# whose selection names none answers as before. The base is a copy of this
# checkout's tracked files, the settings as they stand; the control's base
# drops the selector line, and the queue path then reads free to take the
# admin route. Each row commits one appended line on a base and reads the
# queue-only line of this checkout's change-class.
route_world="$TMP/route-world"
git init -q -b main "$route_world"
git -C "$route_world" config gc.auto 0
git -C "$route_world" config maintenance.auto false
git -C "$ROOT" ls-files -z >"$TMP/route-files"
(cd "$ROOT" && tar --null -T "$TMP/route-files" -cf -) | tar -C "$route_world" -xf -
route_commit() { # MESSAGE
  git -C "$route_world" add -A
  git -C "$route_world" -c user.email=ci-job-set@example.invalid -c user.name=ci-job-set \
    commit -q -m "$1"
  git -C "$route_world" rev-parse HEAD
}
route_base="$(route_commit base)"
grep -v '^HARNESS_CI_QUEUE_SELECTOR = ' "$ROOT/kendex.settings.toml" >"$route_world/kendex.settings.toml"
route_unwired="$(route_commit unwired)"
route_queue() { # BASE PATH EVENT -- the queue-only line for one appended line under PATH on BASE
  git -C "$route_world" checkout -q --detach "$1"
  printf 'route row\n' >>"$route_world/$2"
  route_commit "row $2" >/dev/null
  "$ROOT/skills/harness-ci/scripts/change-class" --repo "$route_world" --event "$3" \
    --base "$1" --head HEAD 2>&1 >/dev/null | sed -n 's/^queue-only: //p'
}
for event in pull_request merge_group; do
  for path in skills/orch/scripts/open-terminal skills/linear/scripts/linear.sh; do
    selected="$(SELECT_EVENT="$event" selection micro false "$path")"
    expected="$(macos_shards "$(field shards <<<"$selected")")"
    check "a change selecting macOS shards takes the queue on $event over $path" \
      "queue_only=true cause=queue-selection selector=tools/ci-job-set output=queue_macos_shards value=$expected" \
      "$(route_queue "$route_base" "$path" "$event")"
  done
  # The UI path is assembled: spelling it whole would make this suite a reader.
  check "a change selecting no queue macOS shard answers as before on $event" \
    "queue_only=false cause=no-queue-path" \
    "$(route_queue "$route_base" "ui/src/App.$(printf tsx)" "$event")"
  check "control: settings naming no selector permit the admin route on $event" \
    "queue_only=false cause=no-queue-path" \
    "$(route_queue "$route_unwired" skills/orch/scripts/open-terminal "$event")"
done

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
