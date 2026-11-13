#!/usr/bin/env bash
# kendex's committed kendex.settings.toml holds the product content a user
# reads or accepts to the standard class: a few changed lines of the Terms or
# of the authoring reference the app compiles in answer standard through the
# repository-standard-path rule, and prove no quick change, so their review
# request stays. Without that setting the same edit is trivial and proves
# one, as any documentation Markdown does.
#
# Lives under tools/tests/: change-scope's own suites ship to every
# repository, and this setting is kendex's alone.
# Inputs: kendex.settings.toml, skills/change-scope/scripts/
set -euo pipefail
# shellcheck source=../../skills/change-scope/tests/lib/sandbox.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../skills/change-scope/tests/lib/sandbox.sh"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"

# The committed settings, and the same file without the setting: the second
# shows the fixture reaches trivial, so the first answers by the setting.
cp "$REPO_ROOT/kendex.settings.toml" "$SANDBOX/settings-committed"
sed '/^HARNESS_CI_STANDARD_PATHS = /d' "$SANDBOX/settings-committed" >"$SANDBOX/settings-without"
if cmp -s "$SANDBOX/settings-committed" "$SANDBOX/settings-without"; then
  echo "FAIL: kendex.settings.toml sets no HARNESS_CI_STANDARD_PATHS line" >&2
  exit 1
fi

# The classifier's stderr for a two-line edit of PATH on a base holding
# SETTINGS.
judge() { # NAME SETTINGS PATH -> stderr
  local repo base head
  repo="$(new_repo "$1")"
  mkdir -p "$repo/$(dirname "$3")"
  cp "$SANDBOX/$2" "$repo/kendex.settings.toml"
  printf '# Text\n\nBody.\n' >"$repo/$3"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m base
  base="$(git -C "$repo" rev-parse HEAD)"
  printf 'More.\nAgain.\n' >>"$repo/$3"
  git -C "$repo" commit -q -am head
  head="$(git -C "$repo" rev-parse HEAD)"
  "$CHANGE_SCOPE" --event pull_request --base "$base" --head "$head" --repo "$repo" 2>&1 >/dev/null
}

# PATH|SETTINGS|the class line's class, measured and cause key|the quick proof
rows=0
while IFS='|' read -r path settings class proved; do
  rows=$((rows + 1))
  err="$(judge "row-$rows" "$settings" "$path")"
  assert_eq "$path on $settings" "$class quick-proof: proved=$proved" \
    "$(sed -n 's/^class: //p' <<<"$err" | cut -d' ' -f1-3) $(sed -n '/^quick-proof: /p' <<<"$err")"
done <<'ROWS'
docs/legal/terms.md|settings-committed|class=standard measured=true cause=repository-standard-path|false
docs/authoring/README.md|settings-committed|class=standard measured=true cause=repository-standard-path|false
docs/legal/terms.md|settings-without|class=trivial measured=true cause=documentation-paths|true
docs/authoring/README.md|settings-without|class=trivial measured=true cause=documentation-paths|true
ROWS
require_rows product-docs "$rows"

report product-docs-class
