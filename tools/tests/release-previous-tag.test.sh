#!/usr/bin/env bash
# Surface: tools/release-previous-tag. Inputs: that script.
# GitHub responses are fixtures; tag retrieval and file comparison use real git.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TOOL="$(cd -- "$TEST_DIR/.." && pwd -P)/release-previous-tag"
TMP_ROOT="$(mktemp -d)" || { echo 'release-previous-tag.test: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo 'release-previous-tag.test: scratch=not-a-directory' >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'release-previous-tag.test: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/home"
: >"$TMP_ROOT/gitconfig"
export GIT_CONFIG_GLOBAL="$TMP_ROOT/gitconfig" GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_COUNT=0
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid

assert_eq() {
  [[ $1 == "$2" ]] || { printf 'FAIL: %s: expected [%s], got [%s]\n' "$3" "$2" "$1" >&2; exit 1; }
  printf 'ok: %s\n' "$3"
}

cat >"$TMP_ROOT/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
[[ $* == 'api --paginate --slurp repos/{owner}/{repo}/releases' ]] || exit 80
cat -- "$RELEASE_FIXTURE"
exit "$RELEASE_STATUS"
GH
chmod +x "$TMP_ROOT/bin/gh"

git init --quiet -b main "$TMP_ROOT/seed"
git -C "$TMP_ROOT/seed" config gc.auto 0
git -C "$TMP_ROOT/seed" config maintenance.auto false
printf 'base\n' >"$TMP_ROOT/seed/notes"
git -C "$TMP_ROOT/seed" add notes
git -C "$TMP_ROOT/seed" commit --quiet -m base
git -C "$TMP_ROOT/seed" checkout --quiet -b release-pr
printf 'release\n' >"$TMP_ROOT/seed/notes"
git -C "$TMP_ROOT/seed" commit --quiet -am release
PR_HEAD=$(git -C "$TMP_ROOT/seed" rev-parse HEAD)
git -C "$TMP_ROOT/seed" tag v1.2.3
git -C "$TMP_ROOT/seed" tag v1.2.2
git -C "$TMP_ROOT/seed" tag main-build-99
git -C "$TMP_ROOT/seed" tag v2.0.0
git -C "$TMP_ROOT/seed" tag rolling-main
git -C "$TMP_ROOT/seed" checkout --quiet main
printf 'main\n' >"$TMP_ROOT/seed/notes"
git -C "$TMP_ROOT/seed" commit --quiet -am main
git clone --quiet --bare "$TMP_ROOT/seed" "$TMP_ROOT/origin.git"
git -C "$TMP_ROOT/origin.git" config gc.auto 0
git -C "$TMP_ROOT/origin.git" config maintenance.auto false
# Leave the release head reachable only through its tag, as after squash merge.
git -C "$TMP_ROOT/origin.git" branch -D release-pr >/dev/null

fresh_clone() {
  CLONE="$TMP_ROOT/$1"
  git clone --quiet --no-local --no-tags --single-branch --branch main "$TMP_ROOT/origin.git" "$CLONE"
  git -C "$CLONE" config gc.auto 0
  git -C "$CLONE" config maintenance.auto false
}

run_tool() {
  RC=0
  (
    cd -- "$CLONE"
    env -i PATH="$TMP_ROOT/bin:$PATH" HOME="$TMP_ROOT/home" \
      GIT_CONFIG_GLOBAL="$TMP_ROOT/gitconfig" GIT_CONFIG_NOSYSTEM=1 \
      RELEASE_FIXTURE="$TMP_ROOT/releases.json" RELEASE_STATUS="${2:-0}" \
      "$BASH" "$1"
  ) >"$TMP_ROOT/out" 2>"$TMP_ROOT/err" || RC=$?
  OUT=$(cat "$TMP_ROOT/out")
}

# The newest stable release is on a later API page, so API order alone cannot
# select the previous stable release.
cat >"$TMP_ROOT/releases.json" <<'JSON'
[
 [{"tag_name":"main-build-99","draft":false,"prerelease":true,"published_at":"2026-10-08T10:00:00Z"},
  {"tag_name":"rolling-main","draft":false,"prerelease":false,"published_at":"2026-10-08T09:00:00Z"},
  {"tag_name":"v2.0.0","draft":true,"prerelease":false,"published_at":null},
  {"tag_name":"v1.2.2","draft":false,"prerelease":false,"published_at":"2026-10-07T10:00:00Z"}],
 [{"tag_name":"v1.2.3","draft":false,"prerelease":false,"published_at":"2026-10-08T08:00:00Z"},
  {"tag_name":"v9.0.0-rc1","draft":false,"prerelease":false,"published_at":"2026-10-08T09:00:00Z"},
  {"tag_name":"v01.2.3","draft":false,"prerelease":false,"published_at":"2026-10-08T09:00:00Z"},
  {"tag_name":"v9.0.0","draft":false,"prerelease":true,"published_at":"2026-10-08T09:00:00Z"}]
]
JSON
cp "$TMP_ROOT/releases.json" "$TMP_ROOT/mixed.json"

fresh_clone missing-tag
if git -C "$CLONE" rev-parse --verify 'v1.2.3^{commit}' >/dev/null 2>&1; then
  echo 'FAIL: clone already has the release tag' >&2
  exit 1
fi
if git -C "$CLONE" cat-file -e "$PR_HEAD" 2>/dev/null; then
  echo 'FAIL: clone already has the release head' >&2
  exit 1
fi
run_tool "$TOOL"
assert_eq "$RC:$OUT" '0:v1.2.3' 'stable release is selected and its missing tag is retrieved'
RESOLVED=$(git -C "$CLONE" rev-parse "$OUT^{commit}")
assert_eq "$RESOLVED" "$PR_HEAD" 'retrieved tag names the release PR head'
DIFF=$(git -C "$CLONE" diff --name-only "$OUT" HEAD)
assert_eq "$DIFF" notes 'comparison resolves a release head outside main'

# Controls mutate owned copies outside the worktree and retain the code text.
python3 - "$TOOL" "$TMP_ROOT" <<'PY'
import pathlib
import sys
source = pathlib.Path(sys.argv[1]).read_text()
root = pathlib.Path(sys.argv[2])
start = source.index("jq -er '") + len("jq -er '")
end = source.index("' <<<", start)
old_selection = source[:start] + '\n  .[0][0].tag_name\n' + source[end:]
assert old_selection != source
(root / 'old-selection.sh').write_text(old_selection)
fetch = 'git fetch origin tag "$tag" >&2'
assert source.count(fetch) == 1
missing_fetch = source.replace(fetch, ': origin tag "$tag" >&2')
assert missing_fetch != source
(root / 'missing-fetch.sh').write_text(missing_fetch)
PY
fresh_clone old-selection
run_tool "$TMP_ROOT/old-selection.sh"
assert_eq "$RC:$OUT" '0:main-build-99' 'old-selection control picks the newer pre-release'

fresh_clone missing-fetch
run_tool "$TMP_ROOT/missing-fetch.sh"
assert_eq "$RC:$OUT" '0:v1.2.3' 'missing-fetch control reaches the comparison'
DIFF_RC=0
git -C "$CLONE" diff --stat "$OUT" HEAD >"$TMP_ROOT/diff" 2>&1 || DIFF_RC=$?
[[ $DIFF_RC != 0 ]] || { echo 'FAIL: comparison passed without fetching the tag' >&2; exit 1; }
printf 'ok: missing-fetch control fails the comparison\n'

# Dependency failures and no stable release must leave no comparison tag.
for row in api-failure empty malformed fetch-failure; do
  fresh_clone "$row"
  status=0
  case "$row" in
    api-failure) cp "$TMP_ROOT/mixed.json" "$TMP_ROOT/releases.json"; status=1 ;;
    empty) printf '[[]]\n' >"$TMP_ROOT/releases.json" ;;
    malformed) printf 'not-json\n' >"$TMP_ROOT/releases.json" ;;
    fetch-failure)
      cp "$TMP_ROOT/mixed.json" "$TMP_ROOT/releases.json"
      git -C "$CLONE" remote set-url origin "$TMP_ROOT/absent.git"
      ;;
  esac
  run_tool "$TOOL" "$status"
  assert_eq "$RC:$OUT" '1:' "$row stops before returning a comparison tag"
done
