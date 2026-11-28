#!/usr/bin/env bash
# Inputs: skills/agent-runtime/scripts/**, skills/orch/scripts/{orch-runtime,setup},
# skills/{agent-runtime,orch}/runtime/{Cargo.toml,Cargo.lock,src/**},
# skills/agent-runtime/tests/setup/cargo, skills/orch/tests/lib/assertions.sh.
set -euo pipefail
ROOT="$(cd -- "${BASH_SOURCE[0]%/*}/../../.." && pwd -P)"
# shellcheck source=../../orch/tests/lib/assertions.sh
. "$ROOT/skills/orch/tests/lib/assertions.sh"
[ "$(uname -sm)" = 'Linux x86_64' ] || { echo 'rowless: CI publishes Linux x86_64 binaries'; exit 0; }
TMP_ROOT="$(mktemp -d)" || { echo 'published-runtime: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo 'published-runtime: scratch=not-a-directory' >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'published-runtime: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

SKILLS="${RUNTIMES_UNDER_TEST:-$ROOT/skills}"
export HOME="$TMP_ROOT/home"
export XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share" XDG_STATE_HOME="$HOME/.local/state" XDG_CACHE_HOME="$HOME/.cache"
export FAKE_CARGO_LOG="$TMP_ROOT/cargo.log" API_LOG="$TMP_ROOT/api.log"
mkdir -p "$HOME" "$TMP_ROOT/bin" "$TMP_ROOT/cargo" "$TMP_ROOT/publish"
for tool in awk bash cat chmod cut find jq ln mkdir mktemp mv rm sha256sum sleep sort timeout uname unzip wc; do
  ln -s "$(command -v "$tool")" "$TMP_ROOT/bin/$tool"
done
ln -s "$ROOT/skills/agent-runtime/tests/setup/cargo" "$TMP_ROOT/cargo/cargo"
cat >"$TMP_ROOT/bin/gh" <<'SH'
#!/bin/bash
set -eu
printf '%s\n' "$*" >>"$API_LOG"
[ "$1 $2 $3" = 'api --hostname github.com' ] || exit 2
api=repos/vanillagreencom/kendex/actions
case "$*" in
  "api --hostname github.com --paginate $api/artifacts?name=$ARTIFACT&per_page=100")
    if [ "$CASE" = absent ]; then echo '{"total_count":0,"artifacts":[]}'; exit; fi
    name="$ARTIFACT"
    [ "$CASE" != wrong-key ] || name="${ARTIFACT%?}"
    expired=false
    [ "$CASE" != expired ] || expired=true
    printf '{"total_count":1,"artifacts":[{"id":11,"name":"%s","expired":%s,"workflow_run":{"id":22}}]}\n' "$name" "$expired"
    ;;
  "api --hostname github.com $api/runs/22")
    if [ "$CASE" = run-unread ]; then exit 124; fi
    if [ "$CASE" = run-invalid ]; then echo '{"id":22}'; exit; fi
    event=push branch=main head=1190866154 workflow=.github/workflows/skill-tests.yml
    case "$CASE" in
      queue) event=merge_group branch=gh-readonly-queue/main/pr-42-abcd ;;
      pr) event=pull_request ;;
      fork) head=123 ;;
      other-workflow) workflow=.github/workflows/other.yml ;;
    esac
    printf '{"id":22,"event":"%s","head_branch":"%s","path":"%s","repository":{"id":1190866154,"full_name":"vanillagreencom/kendex"},"head_repository":{"id":%s}}\n' "$event" "$branch" "$workflow" "$head"
    ;;
  "api --hostname github.com $api/artifacts/11/zip")
    [ "$CASE" != download ] || exit 1
    cat "$ZIP"
    ;;
  *) exit 2 ;;
esac
SH
chmod 755 "$TMP_ROOT/bin/gh"

# shellcheck source=../../agent-runtime/scripts/lib/key.sh
. "$SKILLS/agent-runtime/scripts/lib/key.sh"
for package in agent-runtime orch; do
  name="${package%-runtime}-runtime"
  wrapper="$SKILLS/$package/scripts/$name"
  key="$(agent_runtime_key "$SKILLS/$package/runtime")"
  export ARTIFACT="$name-$key"
  for CASE in push queue cache absent download wrong-key expired pr fork other-workflow checksum incompatible run-unread run-invalid probe-timeout; do
    if [ "$CASE" = probe-timeout ] && [ "$package" != agent-runtime ]; then continue; fi
    case "${1:-}:$CASE" in
      --published-only:push | --publication-errors-only:run-unread | --publication-errors-only:run-invalid | --publication-errors-only:download | --probe-timeout-only:probe-timeout | :*) ;;
      *) continue ;;
    esac
    export CASE
    cache="$TMP_ROOT/$name-$CASE"
    export ZIP="$cache.zip"
    binary="$cache/bin/$ARTIFACT"
    : >"$FAKE_CARGO_LOG"
    : >"$API_LOG"
    cat >"$TMP_ROOT/publish/$ARTIFACT" <<'BINARY'
#!/bin/sh
case "${1:-}:$CASE" in
  --version:incompatible) exit 126 ;;
  --version:probe-timeout) exec sleep 30 ;;
esac
printf 'published argv=%s account=%s\n' "$*" "$ACCOUNT_FIXTURE"
BINARY
    (
      cd "$TMP_ROOT/publish"
      sha256sum "$ARTIFACT" >"$ARTIFACT.sha256"
      [ "$CASE" != checksum ] || printf 'wrong\n' >"$ARTIFACT.sha256"
      python3 -m zipfile -c "$ZIP" "$ARTIFACT" "$ARTIFACT.sha256"
    )
    route="$TMP_ROOT/bin"
    case "$CASE" in
      cache) mkdir -p "$cache/bin"; cp "$TMP_ROOT/publish/$ARTIFACT" "$binary"; chmod 755 "$binary" ;;
      push | queue | absent) route="$TMP_ROOT/cargo:$route" ;;
    esac
    rc=0
    out="$(ACCOUNT_FIXTURE=picked PATH="$route" AGENT_RUNTIME_CACHE="$cache" "$wrapper" version 2>"$TMP_ROOT/err")" || rc=$?
    case "$CASE" in
      push | queue | cache)
        assert_eq "$rc|$out|$(cat "$FAKE_CARGO_LOG")" '0|published argv=version account=picked|' "$name $CASE answers from the artifact without cargo" "$TMP_ROOT/err"
        if cmp -s "$binary" "$TMP_ROOT/publish/$ARTIFACT"; then pass "$name $CASE has the exact binary"; else fail "$name $CASE has the exact binary"; fi
        if [ "$CASE" = cache ]; then assert_eq "$(cat "$API_LOG")" '' "$name shared cache bypasses GitHub"; fi
        ;;
      absent)
        assert_eq "$rc|$out" '0|fake-binary argv=version' "$name falls back to setup" "$TMP_ROOT/err"
        if [ -s "$FAKE_CARGO_LOG" ] && [ -x "$binary" ]; then pass "$name setup compiles the key"; else fail "$name setup compiles the key"; fi
        ;;
      *)
        assert_eq "$rc|$out" '69|' "$name refuses $CASE without cargo" "$TMP_ROOT/err"
        if [ ! -e "$binary" ]; then pass "$name leaves no binary for $CASE"; else fail "$name leaves no binary for $CASE"; fi
        IFS= read -r first <"$TMP_ROOT/err"
        # Jarvis's jarvis_bound forwards only this first line.
        assert_eq "$first" "$name: setup-required key=$key run=$SKILLS/$package/scripts/setup" "$name $CASE preserves the first stderr line"
        case "$CASE" in
          probe-timeout)
            detail="$(awk '/fetch-unavailable/ { print }' "$TMP_ROOT/err")"
            assert_eq "$detail" "$name-fetch: fetch-unavailable cause=fetch-timeout artifact=$ARTIFACT" "$name reports the probe timeout separately"
            ;;
          run-unread | run-invalid)
            cause='run-lookup'
            [ "$CASE" != run-invalid ] || cause='run-parse'
            detail="$(awk '/fetch-unavailable/ { print }' "$TMP_ROOT/err")"
            assert_eq "$detail" "$name-fetch: fetch-unavailable cause=$cause artifact=$ARTIFACT run=22" "$name reports unread provenance for $CASE"
            ;;
        esac
        ;;
    esac
  done
done
if [ "$#" -eq 0 ]; then
  : >"$API_LOG"
  rc=0
  PATH="$TMP_ROOT/bin" AGENT_RUNTIME_CACHE="$TMP_ROOT/hook" "$SKILLS/orch/scripts/orch-runtime" turn-end --hook-dir "$TMP_ROOT" 2>"$TMP_ROOT/err" || rc=$?
  assert_eq "$rc|$(cat "$API_LOG")" '69|' 'orch mail hook leaves setup to the detached route' "$TMP_ROOT/err"
fi
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
