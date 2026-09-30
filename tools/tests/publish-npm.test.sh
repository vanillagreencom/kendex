#!/usr/bin/env bash
# tools/publish-npm: how it reads a release tag, what it refuses, when it
# publishes, what it publishes, and how it confirms. Every run is over a
# world built here: a tree holding the tool and one package,
# pi-extensions/pi-demo at 1.2.3, with origin/main at its commit and the tag
# pi-demo-v1.2.3 on it. An `npm` stub in front of PATH answers `--version`,
# `view`, `ci` and `publish` the way its row says, so no run reaches the
# registry; its `publish` records the version of the package.json it was run
# beside, and refuses to run inside the checkout.
#
# A run renders as `rc=<n> keys=<k=v,...> npm=<verb,...>`: the exit status,
# every `publish-npm: <key>=<value>` line in order, and every npm verb the
# stub received in order, `publish@<version>` for a publish. The English
# under a keyed line is not pinned.
#
# The rows table is `label|world|argv|npm|served|publish|rc|keys|verbs`:
#   world    main     the tag on origin/main, checked out
#            prepack  main, and the package declares a prepack script
#            side     the tag on a commit origin/main does not hold, checked out
#            later    the tag on origin/main's parent; origin/main, checked
#                     out, has added a file to the package since, its
#                     version still 1.2.3
#            ahead    the tag on origin/main's parent; origin/main, checked
#                     out, has changed only a file outside the package since
#            foreign  main, and the package is named @other/pi-demo
#            broken   main, and package.json is not JSON
#   argv     the arguments as written
#   npm      what `npm --version` prints
#   served   what `npm view` answers; every mode but absent and down serves
#            the package itself, and each names what it answers for the version
#            no      E404 until a publish succeeds, then the version
#            yes     the version from the start
#            never   E404 always
#            late    E404 until one read after a publish, then the version
#            absent  E404 for the package, so for the version too
#            down    exit 1 with a network error for the package
#            vdown   exit 1 with a network error for the version
#   publish  ok or fail
#
# The last block cuts each guard out of a copy of the tool, between its
# `# guard <rule>: begin` and `end` markers, and runs that guard's row
# again: the row must go red, which is what makes it a row about the guard.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/../.." && pwd)"
TMP_ROOT="$(mktemp -d)" || { echo "publish-npm.test: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "publish-npm.test: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "publish-npm.test: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

ID=@vanillagreen/pi-demo@1.2.3

# The npm stub: answers from STUB_* and appends each verb to $STUB_DIR/verbs.
mkdir -p "$TMP_ROOT/bin"
cat >"$TMP_ROOT/bin/npm" <<'EOF_NPM'
#!/usr/bin/env bash
set -u
verb="$1"
[ "$verb" = --version ] && verb=version
printf '%s\n' "$verb" >>"$STUB_DIR/verbs"
case "$1" in
  --version) printf '%s\n' "$STUB_NPM_VERSION" ;;
  view)
    spec="$2"
    if [ "${3:-}" = name ]; then
      case "$STUB_SERVED" in
        down) printf 'npm error code ECONNRESET\n' >&2; exit 1 ;;
        absent) printf 'npm error code E404\nnpm error 404 Not Found - GET %s - Not found\n' "$spec" >&2; exit 1 ;;
        *) printf '%s\n' "$spec" ;;
      esac
      exit 0
    fi
    case "$STUB_SERVED" in
      yes) printf '%s\n' "${spec##*@}" ;;
      no)
        if [ -f "$STUB_DIR/published" ]; then printf '%s\n' "${spec##*@}"; else
          printf 'npm error code E404\nnpm error 404 No match found for version %s\n' "${spec##*@}" >&2; exit 1
        fi ;;
      never) printf 'npm error code E404\n' >&2; exit 1 ;;
      late)
        if [ -f "$STUB_DIR/published" ] && [ -f "$STUB_DIR/lagged" ]; then printf '%s\n' "${spec##*@}"; else
          [ -f "$STUB_DIR/published" ] && : >"$STUB_DIR/lagged"
          printf 'npm error code E404\n' >&2; exit 1
        fi ;;
      absent) printf 'npm error code E404\nnpm error 404 Not Found - GET %s - Not found\n' "${spec%@*}" >&2; exit 1 ;;
      down|vdown) printf 'npm error code ECONNRESET\n' >&2; exit 1 ;;
    esac ;;
  ci) [ "$2" = --ignore-scripts ] || { echo "stub: npm ci without --ignore-scripts" >&2; exit 9; } ;;
  publish)
    [ -f package.json ] || { echo "stub: npm publish outside the package" >&2; exit 9; }
    case "$(pwd -P)/" in "$STUB_TREE"/*) echo "stub: npm publish inside the checkout" >&2; exit 9 ;; esac
    [ "${2:-}" = --provenance ] || { echo "stub: npm publish without --provenance" >&2; exit 9; }
    sed -i.bak '$d' "$STUB_DIR/verbs" && rm -- "$STUB_DIR/verbs.bak"
    printf 'publish@%s\n' "$(jq -r .version package.json)" >>"$STUB_DIR/verbs"
    [ "$STUB_PUBLISH" = ok ] || { echo "stub: publish refused" >&2; exit 1; }
    : >"$STUB_DIR/published" ;;
  *) echo "stub: unexpected npm $*" >&2; exit 9 ;;
esac
EOF_NPM
chmod +x "$TMP_ROOT/bin/npm"

commit() { git -C "$1" -c user.name=world -c user.email=world@example.invalid commit --quiet --allow-empty -am "$2"; }

# world KIND [TOOL] — a fresh world; prints its directory. TOOL is the copy
# of publish-npm to install (default the tracked one).
world() {
  local kind="$1" tool="${2:-$REPO/tools/publish-npm}" dir tree
  dir="$(mktemp -d "$TMP_ROOT/w.XXXXXX")"
  tree="$dir/tree"
  mkdir -p "$tree/tools" "$tree/pi-extensions/pi-demo" "$dir/stub"
  cp -- "$tool" "$tree/tools/publish-npm"
  chmod +x "$tree/tools/publish-npm"
  case "$kind" in
    foreign) printf '{"name":"@other/pi-demo","version":"1.2.3"}\n' ;;
    prepack) printf '{"name":"@vanillagreen/pi-demo","version":"1.2.3","scripts":{"prepack":"npm run build"}}\n' ;;
    broken) printf '{"name":\n' ;;
    *) printf '{"name":"@vanillagreen/pi-demo","version":"1.2.3"}\n' ;;
  esac >"$tree/pi-extensions/pi-demo/package.json"
  git -C "$tree" init --quiet
  git -C "$tree" add --all
  commit "$tree" base
  case "$kind" in
    side)
      git -C "$tree" update-ref refs/remotes/origin/main HEAD
      commit "$tree" unmerged
      git -C "$tree" tag pi-demo-v1.2.3 ;;
    later)
      git -C "$tree" tag pi-demo-v1.2.3
      printf 'export {};\n' >"$tree/pi-extensions/pi-demo/index.js"
      git -C "$tree" add pi-extensions/pi-demo/index.js
      commit "$tree" code
      git -C "$tree" update-ref refs/remotes/origin/main HEAD ;;
    ahead)
      git -C "$tree" tag pi-demo-v1.2.3
      printf 'outside the package\n' >"$tree/NOTES"
      git -C "$tree" add NOTES
      commit "$tree" outside
      git -C "$tree" update-ref refs/remotes/origin/main HEAD ;;
    *)
      git -C "$tree" update-ref refs/remotes/origin/main HEAD
      git -C "$tree" tag pi-demo-v1.2.3
      git -C "$tree" tag pi-demo-v1.2.4
      git -C "$tree" tag pi-gone-v1.0.0 ;;
  esac
  printf '%s\n' "$dir"
}

# run DIR NPM SERVED PUBLISH ARGV... — sets RC, OUT, RESULT
run() {
  local dir="$1" npm="$2" served="$3" publish="$4" line keys verbs
  shift 4
  RC=0
  OUT="$(cd "$dir/tree" && PATH="$TMP_ROOT/bin:$PATH" STUB_DIR="$dir/stub" STUB_TREE="$dir/tree" STUB_NPM_VERSION="$npm" \
    STUB_SERVED="$served" STUB_PUBLISH="$publish" PUBLISH_NPM_VIEW_ATTEMPTS=3 PUBLISH_NPM_VIEW_INTERVAL=0 \
    tools/publish-npm "$@" 2>&1)" || RC=$?
  keys=""
  while IFS= read -r line; do
    case "$line" in 'publish-npm: '*) keys="$keys,${line#publish-npm: }" ;; esac
  done <<EOF_OUT
$OUT
EOF_OUT
  keys="${keys#,}"
  verbs=""
  if [ -f "$dir/stub/verbs" ]; then verbs="$(tr '\n' ',' <"$dir/stub/verbs")"; fi
  verbs="${verbs%,}"
  RESULT="rc=$RC keys=${keys:--} npm=${verbs:--}"
}

rows="
publish from main|main|pi-demo-v1.2.3|11.6.0|no|ok|0|published=$ID|version,view,view,publish@1.2.3,view
npm at the floor, first read after the publish E404|main|pi-demo-v1.2.3|11.5.1|late|ok|0|published=$ID|version,view,view,publish@1.2.3,view,view
prepack package installs its tools first|prepack|pi-demo-v1.2.3|11.6.0|no|ok|0|published=$ID|version,view,view,ci,publish@1.2.3,view
dry run stops before publishing|main|--dry-run pi-demo-v1.2.3|11.6.0|no|ok|0|dry-run=$ID|version,view,view
already served publishes nothing|main|pi-demo-v1.2.3|11.6.0|yes|ok|0|served=$ID|version,view,view
not a release tag|main|pi-demo-1.2.3|11.6.0|no|ok|1|tag=pi-demo-1.2.3|-
app release tag|main|v1.2.3|11.6.0|no|ok|1|tag=v1.2.3|-
tag missing|main|pi-demo-v9.9.9|11.6.0|no|ok|1|absent=pi-demo-v9.9.9|-
checkout ahead of the tag outside the package publishes|ahead|pi-demo-v1.2.3|11.6.0|no|ok|0|published=$ID|version,view,view,publish@1.2.3,view
package changed on main since the tag|later|pi-demo-v1.2.3|11.6.0|no|ok|1|moved=pi-demo-v1.2.3|version,view,view
served before the package-change check|later|pi-demo-v1.2.3|11.6.0|yes|ok|0|served=$ID|version,view,view
tag off the default branch|side|pi-demo-v1.2.3|11.6.0|no|ok|1|off-main=TAGGED|-
no such package|main|pi-gone-v1.0.0|11.6.0|no|ok|1|package=pi-gone|-
package.json not JSON|broken|pi-demo-v1.2.3|11.6.0|no|ok|1|package=pi-demo|-
package named outside the scope|foreign|pi-demo-v1.2.3|11.6.0|no|ok|1|name=@other/pi-demo|-
manifest version differs from the tag|main|pi-demo-v1.2.4|11.6.0|no|ok|1|version=1.2.3|-
npm below the trusted-publishing floor|main|pi-demo-v1.2.3|11.5.0|no|ok|1|npm=11.5.0|version
npm 10 below the floor|main|pi-demo-v1.2.3|10.9.2|no|ok|1|npm=10.9.2|version
registry lookup fails|main|pi-demo-v1.2.3|11.6.0|down|ok|1|lookup=@vanillagreen/pi-demo|version,view
version lookup fails|main|pi-demo-v1.2.3|11.6.0|vdown|ok|1|lookup=$ID|version,view,view
npm serves no version of the package|main|pi-demo-v1.2.3|11.6.0|absent|ok|1|first-release=@vanillagreen/pi-demo|version,view
first release dry run|main|--dry-run pi-demo-v1.2.3|11.6.0|absent|ok|1|first-release=@vanillagreen/pi-demo|version,view
publish fails|main|pi-demo-v1.2.3|11.6.0|no|fail|1|publish=$ID|version,view,view,publish@1.2.3
published version never served|main|pi-demo-v1.2.3|11.6.0|never|ok|1|unconfirmed=$ID|version,view,view,publish@1.2.3,view,view,view
unknown option|main|--nope pi-demo-v1.2.3|11.6.0|no|ok|2|option=--nope|-
no tag|main|--dry-run|11.6.0|no|ok|2|option=no-tag|-
"

# expect DIR KEYS — KEYS with TAGGED replaced by the commit pi-demo-v1.2.3 names
expect() {
  local sha
  sha="$(git -C "$1/tree" rev-parse 'pi-demo-v1.2.3^{commit}')"
  printf '%s\n' "${2//TAGGED/$sha}"
}

while IFS='|' read -r label kind argv npm served publish rc keys verbs; do
  [ -n "$label" ] || continue
  dir="$(world "$kind")"
  keys="$(expect "$dir" "$keys")"
  # shellcheck disable=SC2086
  run "$dir" "$npm" "$served" "$publish" $argv
  want="rc=$rc keys=$keys npm=$verbs"
  if [ "$RESULT" = "$want" ]; then
    ok "$label: $want"
  else
    bad "$label: want $want" "got $RESULT
$OUT"
  fi
done <<EOF_ROWS
$rows
EOF_ROWS

# The must-fail controls, one per guard: `rule|row label`. Each guard is cut
# out of a copy of the tool, and its row, run over that copy, must no longer
# give the row's answer.
controls="
tag|not a release tag
absent|tag missing
off-main|tag off the default branch
package|no such package
name|package named outside the scope
version|manifest version differs from the tag
npm|npm below the trusted-publishing floor
lookup|registry lookup fails
first-release|npm serves no version of the package
served|already served publishes nothing
moved|package changed on main since the tag
"
while IFS='|' read -r rule label; do
  [ -n "$rule" ] || continue
  row="$(printf '%s\n' "$rows" | grep -F -- "$label|")" || { bad "control $rule: no row labelled [$label]"; continue; }
  IFS='|' read -r _ kind argv npm served publish rc keys verbs <<<"$row"
  cut="$TMP_ROOT/publish-npm.$rule"
  begin="# guard $rule: begin"
  end="# guard $rule: end"
  # A marker may be indented; rule names are [a-z-], so they match as written.
  if [ "$(grep -cE -- "^[[:space:]]*$begin\$" "$REPO/tools/publish-npm")" != 1 ] || [ "$(grep -cE -- "^[[:space:]]*$end\$" "$REPO/tools/publish-npm")" != 1 ]; then
    bad "control $rule: the tool does not carry exactly one pair of [$begin] markers"
    continue
  fi
  sed "/^[[:space:]]*$begin\$/,/^[[:space:]]*$end\$/d" "$REPO/tools/publish-npm" >"$cut"
  if cmp -s -- "$cut" "$REPO/tools/publish-npm"; then
    bad "control $rule: the cut changed nothing"
    continue
  fi
  dir="$(world "$kind" "$cut")"
  keys="$(expect "$dir" "$keys")"
  # shellcheck disable=SC2086
  run "$dir" "$npm" "$served" "$publish" $argv
  want="rc=$rc keys=$keys npm=$verbs"
  if [ "$RESULT" != "$want" ]; then
    ok "control $rule: without the guard, [$label] gives $RESULT"
  else
    bad "control $rule: without the guard, [$label] still gives $want"
  fi
done <<EOF_CONTROLS
$controls
EOF_CONTROLS

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
