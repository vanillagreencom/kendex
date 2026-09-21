#!/usr/bin/env bash
# One class per diff, at every class and every boundary, and standard for
# every diff the script cannot prove into a narrower one.
#
# The render rows stand a `kendex` on PATH whose exit status the row sets.
# That program is the judgement the script delegates to, not a copy of it:
# what these rows pin is that the script calls it and answers to its verdict,
# so the must-fail control — a classifier that trusts .kendex-generated.json
# and skips the call — reds the hand-edit row.
set -euo pipefail
# shellcheck source=lib/sandbox.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/sandbox.sh"

repo="$(new_repo change-class)"
# This suite's own inventory: a consumer that generates a configuration file
# reaches the configuration rule, which the shared fixture's set never would.
printf '%s\n' '[".kendex-generated.json",".kendex-lock.json",".agents/skills/orch/SKILL.md","CLAUDE.md","kendex.toml"]' >"$repo/.kendex-generated.json"
commit_paths "$repo" baseline seed.txt
base="$(git -C "$repo" rev-parse HEAD)"

# The dependency double: one program named kendex, answering with the status
# the row recorded. PATH carries it alone so nothing else resolves from it.
stub_bin="$SANDBOX/stub-bin"
mkdir -p "$stub_bin"
cat >"$stub_bin/kendex" <<'STUB'
#!/usr/bin/env bash
exit "$(cat "$KENDEX_STUB_STATUS")"
STUB
chmod +x "$stub_bin/kendex"
export KENDEX_STUB_STATUS="$SANDBOX/kendex-status"
echo 0 >"$KENDEX_STUB_STATUS"

# A PATH with every directory that holds a kendex dropped, so the row that
# proves the fail-closed answer is not decided by the developer's own install.
no_kendex_path=""
while IFS= read -r dir; do
  [ -n "$dir" ] || continue
  [ ! -x "$dir/kendex" ] || continue
  no_kendex_path="${no_kendex_path:+$no_kendex_path:}$dir"
done <<<"$(printf '%s' "$PATH" | tr ':' '\n')"

reset_case() {
  git -C "$repo" checkout -q -B case "$base"
  git -C "$repo" clean -qfd
}

# LINES lines of content under PATH, so a row names the size it means.
write_lines() { # PATH COUNT
  local n=0
  mkdir -p "$repo/$(dirname "$1")"
  while [ "$n" -lt "$2" ]; do
    n=$((n + 1))
    printf 'line %d\n' "$n" >>"$repo/$1"
  done
}

# label | expected | verify status | file:lines pairs
table_rows=0
while IFS='|' read -r label expected verify files; do
  table_rows=$((table_rows + 1))
  reset_case
  echo "$verify" >"$KENDEX_STUB_STATUS"
  for spec in $files; do
    write_lines "${spec%:*}" "${spec##*:}"
  done
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "$label"
  PATH="$stub_bin:$PATH" assert_class "$label" "$expected" \
    --repo "$repo" --event pull_request --base "$base" --head HEAD
done <<'CASES'
render-only|render|0|.agents/skills/orch/SKILL.md:4 CLAUDE.md:2
render-customized-consumer|render|0|.agents/skills/orch/SKILL.md:40
render-hand-edit|standard|1|.agents/skills/orch/SKILL.md:400
render-with-configuration|standard|0|.agents/skills/orch/SKILL.md:400 kendex.toml:2
render-inventory-gain|standard|0|.kendex-generated.json:1 runtime/agent.conf:2
trivial-at-ceiling|trivial|1|docs/guide.md:20
trivial-one-over|small|1|docs/guide.md:21
micro-at-ceiling|micro|1|runtime/agent.conf:20
micro-one-over|small|1|runtime/agent.conf:21
small-at-ceiling|small|1|runtime/agent.conf:150
small-one-over|standard|1|runtime/agent.conf:151
small-two-subsystems|standard|1|runtime/agent.conf:30 payload/data.conf:30
excluded-path|standard|1|.github/workflows/ci.yml:3
CASES
require_rows change-class-table "$table_rows"

# A class is never read from an author-writable field. The branch name and the
# label say render; the diff says otherwise and the diff decides.
reset_case
git -C "$repo" checkout -q -B render "$base"
write_lines runtime/agent.conf 400
git -C "$repo" add -A
git -C "$repo" commit -q -m "branch named render"
PATH="$stub_bin:$PATH" GITHUB_PR_LABELS=render assert_class \
  "a branch name and a label assert nothing" standard \
  --repo "$repo" --event pull_request --base "$base" --head HEAD

# No flag asserts a class either.
out="$("$CHANGE_CLASS" --class render --event pull_request --repo "$repo" \
  --base "$base" 2>&1)" && status=0 || status=$?
assert_eq "no flag asserts a class" "wiring-error: cause=unknown-argument argument=--class exit 2" \
  "$(printf '%s\n' "$out" | sed -n 1p) exit $status"

# The verify step is the render class's proof, so a checkout with no kendex on
# PATH proves nothing and takes the fail-closed class.
reset_case
write_lines .agents/skills/orch/SKILL.md 400
git -C "$repo" add -A
git -C "$repo" commit -q -m "render with no verifier"
PATH="$no_kendex_path" assert_class "no verifier leaves render unproven" standard \
  --repo "$repo" --event pull_request --base "$base" --head HEAD

# A measured class needs the merge-base range only a pull request defines.
PATH="$stub_bin:$PATH" assert_class "push carries no measured class" standard \
  --repo "$repo" --event push --base "$base" --head HEAD

# The verdict reaches the GitHub output file, and the paths file carries the
# set the class was read from.
reset_case
write_lines docs/guide.md 2
git -C "$repo" add -A
git -C "$repo" commit -q -m "wiring outputs"
output_file="$SANDBOX/change-class-output"
paths_file="$SANDBOX/change-class-paths"
out="$(PATH="$stub_bin:$PATH" "$CHANGE_CLASS" --repo "$repo" \
  --event pull_request --base "$base" --head HEAD \
  --output "$output_file" --paths-output "$paths_file" 2>/dev/null)"
assert_eq "the verdict reaches every output" \
  "change_class=trivial stdout=change_class=trivial paths=docs/guide.md" \
  "$(cat "$output_file") stdout=$out paths=$(cat "$paths_file")"

# The repository's own allowlist replaces the shipped documentation set.
reset_case
write_lines runtime/agent.conf 2
git -C "$repo" add -A
git -C "$repo" commit -q -m "configured allowlist"
PATH="$stub_bin:$PATH" HARNESS_CI_TRIVIAL_PATHS='runtime/*' \
  assert_class "a configured allowlist decides trivial" trivial \
  --repo "$repo" --event pull_request --base "$base" --head HEAD
PATH="$stub_bin:$PATH" HARNESS_CI_TRIVIAL_MAX_LINES=1 \
  assert_class "a configured ceiling refuses trivial" micro \
  --repo "$repo" --event pull_request --base "$base" --head HEAD

# Must-fail control: a classifier that trusts .kendex-generated.json instead of
# the render answers render on the hand-edit row. The mutant stands in a
# package layout of its own so it resolves the same siblings the real script
# does, and only the provenance proof is taken out.
mutant_root="$SANDBOX/mutant"
mkdir -p "$mutant_root/harness-ci/scripts"
ln -s "$(dirname "$CHANGE_CLASS")/harness-only" "$mutant_root/harness-ci/scripts/harness-only"
ln -s "$(cd "$(dirname "$CHANGE_CLASS")/../../orch" && pwd)" "$mutant_root/orch"
mutant="$mutant_root/harness-ci/scripts/change-class"
sed 's/elif renders_match; then/elif true; then/' "$CHANGE_CLASS" >"$mutant"
chmod +x "$mutant"
assert_eq "the control removes exactly one call" 1 \
  "$(grep -c '^  elif true; then$' "$mutant")"

reset_case
write_lines .agents/skills/orch/SKILL.md 400
git -C "$repo" add -A
git -C "$repo" commit -q -m "control: hand edit inside a render"
echo 1 >"$KENDEX_STUB_STATUS"
control_out="$(PATH="$stub_bin:$PATH" \
  "$mutant" --repo "$repo" --event pull_request --base "$base" --head HEAD \
  2>/dev/null)"
assert_eq "a classifier trusting the manifest passes the hand-edit row" \
  "change_class=render" "$control_out"

report change-class
