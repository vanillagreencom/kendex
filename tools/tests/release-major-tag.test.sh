#!/usr/bin/env bash
# Surface: the major-tag job of .github/workflows/release.yml, which moves
# v<major> to a published stable release. Inputs: that workflow's step
# "Move the major tag to this release", run as written.
# The GitHub refs API is a stub that applies each update to a fixture origin;
# tags, ancestry and version reads use real git.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
WORKFLOW="$(cd -- "$TEST_DIR/../.." && pwd -P)/.github/workflows/release.yml"
TMP_ROOT="$(mktemp -d)" || { echo "release-major-tag.test: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "release-major-tag.test: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "release-major-tag.test: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/home"
: >"$TMP_ROOT/gitconfig"
export GIT_CONFIG_GLOBAL="$TMP_ROOT/gitconfig" GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
REPOSITORY=vanillagreencom/kendex

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

STEP=$(awk '
  $0 == "      - name: Move the major tag to this release" { in_step = 1; next }
  in_step && $0 == "        run: |" { in_run = 1; next }
  in_run && $0 != "" && $0 !~ /^          / { exit }
  in_run { sub(/^          /, ""); print }
' "$WORKFLOW") || fail "extract: awk failed on $WORKFLOW"
[[ $STEP == *'gh api'* && $STEP == *'git merge-base --is-ancestor'* ]] || fail "extract: no major-tag step body in $WORKFLOW"

# The refs API as the step calls it: PATCH moves an existing tag, POST
# creates one, and either answers an error the way GitHub does.
cat >"$TMP_ROOT/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GH_LOG"
[ -z "${GH_FAIL:-}" ] || { echo 'Repository rule violations found' >&2; exit 1; }
[ "$1" = api ] || exit 80
shift
method="" path="" ref="" sha="" force=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --method) method=$2; shift 2 ;;
    -f | -F)
      case "$2" in
        ref=*) ref=${2#ref=} ;;
        sha=*) sha=${2#sha=} ;;
        force=true) force=true ;;
        *) exit 81 ;;
      esac
      shift 2 ;;
    *) path=$1; shift ;;
  esac
done
case "$method $path" in
  "PATCH repos/$GITHUB_REPOSITORY/git/refs/tags/"*)
    [ "$force" = true ] || exit 82
    ref="refs/tags/${path#repos/"$GITHUB_REPOSITORY"/git/refs/tags/}"
    git -C "$ORIGIN" rev-parse --verify --quiet "$ref" >/dev/null || exit 83 ;;
  "POST repos/$GITHUB_REPOSITORY/git/refs")
    ! git -C "$ORIGIN" rev-parse --verify --quiet "$ref" >/dev/null || exit 84 ;;
  *) exit 85 ;;
esac
git -C "$ORIGIN" update-ref "$ref" "$sha"
GH
chmod +x "$TMP_ROOT/bin/gh"

SEED="$TMP_ROOT/seed"
git init --quiet -b main "$SEED"
commit() { git -C "$SEED" commit --quiet --allow-empty -m "$1"; git -C "$SEED" rev-parse HEAD; }
c16=$(commit c16); git -C "$SEED" tag v1.16.0
c17=$(commit c17); git -C "$SEED" tag -a v1.17.0 -m v1.17.0
c18=$(commit c18); git -C "$SEED" tag v1.18.0; git -C "$SEED" tag v1.18.0+build.1
git -C "$SEED" checkout --quiet -b side
side=$(commit side); git -C "$SEED" tag v1.18.1
git -C "$SEED" checkout --quiet main
c19=$(commit c19); git -C "$SEED" tag v1.19.0-rc.1
c20=$(commit c20); git -C "$SEED" tag v2.0.0
git -C "$SEED" branch -D side >/dev/null
git -C "$SEED" tag v1 "$c17"
git clone --quiet --bare "$SEED" "$TMP_ROOT/origin.git"
[ "$c16" != "$c17" ] || fail "fixture: distinct commits"

# Each row starts from a fresh origin whose v1 is at $2 and runs the step in
# a clone, as the job's full-history checkout leaves it. It returns 0 when
# the exit status, the target of the expected major tag and the API call
# count all match, so a mutant can show the same row turning red.
row() {
  local script=$1 name=$2 at=$3 tag=$4 prerelease=$5 want_status=$6 major=$7 want_target=$8 want_calls=$9 gh_fail=${10:-}
  local dir="$TMP_ROOT/rows/$name" status=0 target calls
  rm -rf -- "$dir"
  mkdir -p "$dir"
  cp -R "$TMP_ROOT/origin.git" "$dir/origin.git"
  git -C "$dir/origin.git" update-ref refs/tags/v1 "$at"
  git clone --quiet "$dir/origin.git" "$dir/work"
  : >"$dir/gh.log"
  (cd "$dir/work" && env -i PATH="$TMP_ROOT/bin:$PATH" HOME="$TMP_ROOT/home" \
    GIT_CONFIG_GLOBAL="$GIT_CONFIG_GLOBAL" GIT_CONFIG_NOSYSTEM=1 \
    GITHUB_REPOSITORY="$REPOSITORY" GH_TOKEN=fixture GH_LOG="$dir/gh.log" GH_FAIL="$gh_fail" \
    ORIGIN="$dir/origin.git" RELEASE_TAG="$tag" PRERELEASE="$prerelease" \
    "$BASH" -c "$script") >"$dir/out" 2>&1 || status=$?
  target=$(git -C "$dir/origin.git" rev-parse --verify --quiet "refs/tags/$major^{commit}") || target=none
  calls=$(wc -l <"$dir/gh.log")
  calls=$((calls))
  if [ "$status" -eq "$want_status" ] && [ "$target" = "$want_target" ] && [ "$calls" -eq "$want_calls" ]; then
    return 0
  fi
  printf '%s: status=%s/%s %s=%s/%s calls=%s/%s\n' "$name" "$status" "$want_status" "$major" "$target" "$want_target" "$calls" "$want_calls" >&2
  sed 's/^/  | /' "$dir/out" >&2
  return 1
}

# name | v1 before | published tag | prerelease | status | major | major after | API calls | API refuses
ROWS="
stable-newer|$c17|v1.18.0|false|0|v1|$c18|1|
new-major|$c17|v2.0.0|false|0|v2|$c20|1|
prerelease|$c17|v1.19.0-rc.1|true|0|v1|$c17|0|
older-version|$c17|v1.16.0|false|0|v1|$c17|0|
already-current|$c18|v1.18.0|false|0|v1|$c18|0|
off-main|$c17|v1.18.1|false|1|v1|$c17|0|
build-metadata|$c17|v1.18.0+build.1|false|1|v1|$c17|0|
api-refused|$c17|v1.18.0|false|1|v1|$c17|1|1
"

run_row() {
  local script=$1 want=$2 line
  line=$(grep "^$want|" <<<"$ROWS") || fail "rows: no row $want"
  IFS='|' read -r name at tag prerelease status major target calls gh_fail <<<"$line"
  row "$script" "$name" "$at" "$tag" "$prerelease" "$status" "$major" "$target" "$calls" "$gh_fail"
}

while IFS='|' read -r name _; do
  [ -n "$name" ] || continue
  run_row "$STEP" "$name" || fail "row $name"
  printf 'ok: %s\n' "$name"
done <<<"$ROWS"

# One control per rule: each edit of a disposable copy of the step must turn
# the row that rule holds red.
CONTROLS=(
  'prerelease|if [ "$PRERELEASE" != false ]; then|if false; then'
  'build-metadata|\.([0-9]+)\.([0-9]+)$ ]]; then|\.([0-9]+)\.([0-9]+) ]]; then'
  'off-main|if ! git merge-base --is-ancestor "$commit" origin/main; then|if false; then'
  'older-version|cause=newer held=$name"|cause=newer held=$name"; continue'
)
for control in "${CONTROLS[@]}"; do
  name=${control%%|*} rest=${control#*|}
  original=${rest%%|*} replacement=${rest#*|}
  count=$(grep -cF -- "$original" <<<"$STEP") || count=0
  [ "$count" -eq 1 ] || fail "control $name: match count $count"
  mutant=${STEP/"$original"/"$replacement"}
  [ "$mutant" != "$STEP" ] || fail "control $name: edit changed nothing"
  if run_row "$mutant" "$name" 2>/dev/null; then
    fail "control $name: the mutant passed its row"
  fi
  printf 'ok: control %s\n' "$name"
done
