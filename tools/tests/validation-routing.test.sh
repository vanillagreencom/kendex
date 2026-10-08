#!/usr/bin/env bash
# kendex's committed commands must keep every local fallback on a range.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/lib/guard-world.sh"

for skill in orch github harness-ci; do
  ln -s "$REPO/.agents/skills/$skill" "$R/.agents/skills/$skill"
done
mkdir -p "$R/bin"
cat > "$R/bin/gh" <<'SH'
#!/usr/bin/env bash
printf 'no pull requests found\n' >&2
exit 1
SH
chmod +x "$R/bin/gh"
cat > "$R/tools/guard" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ROUTE_LOG"
case " $* " in *' --full '*) exit 17 ;; esac
exec "$ACTUAL_GUARD" "$@"
SH
chmod +x "$R/tools/guard"
git -C "$R" add -A
git -C "$R" commit -q -m route
BASE="$(git -C "$R" rev-parse HEAD)"
git -C "$R" update-ref refs/remotes/origin/main "$BASE"
printf '# changed\n' >> "$R/skills/demo/scripts/demo.sh"
printf '# changed\n' >> "$R/.agents/skills/demo/scripts/demo.sh"
ROUTE_LOG="$TMP/routes"
export ROUTE_LOG ACTUAL_GUARD="$GUARD"

route_command() { # SETTING BASE
  local command
  command="$(cd "$R" && env -u DEV_VALIDATE_CMD -u DEV_VALIDATE_RANGE_CMD -u DEV_VALIDATE_SELECTION_CMD "$REPO/skills/orch/scripts/orch-env" "$1" '')"
  : > "$ROUTE_LOG"
  RC=0
  OUT="$(cd "$R" && DEV_VALIDATE_BASE="$2" "$BASH" -c "$command" 2>&1)" || RC=$?
}
for row in "DEV_VALIDATE_CMD|" "DEV_VALIDATE_RANGE_CMD|$BASE" "DEV_VALIDATE_SELECTION_CMD|" "DEV_VALIDATE_SELECTION_CMD|$BASE"; do
  IFS='|' read -r setting base <<<"$row"
  route_command "$setting" "$base"
  [ "$RC" -eq 0 ] && grep -qF -- "--range $BASE" "$ROUTE_LOG" \
    && ok "$setting uses an explicit range with base [$base]" || bad "$setting uses an explicit range with base [$base]" "$OUT"
done

# An all-suite preview before the PR opens uses the configured scoped route.
printf 'changed\n' > "$R/tools/unmapped"
DEV_VALIDATE_SCOPED=true route_command DEV_VALIDATE_SELECTION_CMD ''
[ "$RC" -eq 0 ] && grep -qF -- "--selection --range $BASE" "$ROUTE_LOG" && [[ $OUT == *scoped=true* ]] \
  && ok 'the configured pre-open scoped route remains a range' || bad 'the configured pre-open scoped route remains a range' "$OUT"

# The real bounded runner reads the same settings for initial and CI fallback.
for mode in full ci; do
  : > "$ROUTE_LOG"
  RC=0
  args=()
  [ "$mode" != ci ] || args=(--validate-mode ci --base "$BASE")
  OUT="$(cd "$R" && env -u DEV_VALIDATE_CMD -u DEV_VALIDATE_RANGE_CMD -u DEV_VALIDATE_SELECTION_CMD \
    PATH="$R/bin:$PATH" "$REPO/skills/orch/scripts/dev-validate-run" --worktree "$R" ${args[@]+"${args[@]}"} --poll 1 2>&1)" || RC=$?
  [ "$RC" -eq 0 ] && grep -qF -- "--range $BASE" "$ROUTE_LOG" \
    && ! grep -qF -- --full "$ROUTE_LOG" && [[ $OUT == *validate=pass* ]] \
    && ok "the runner's $mode request keeps local execution on range" || bad "the runner's $mode request keeps local execution on range" "$OUT"
done

# A committed documentation change must reach its reader when CI refuses
# coverage. Passing HEAD as the base would hide the failing reader.
printf 'tmp/\n' > "$R/.gitignore"
git -C "$R" add -A
git -C "$R" commit -q -m before-document
BASE="$(git -C "$R" rev-parse HEAD)"
git -C "$R" update-ref refs/remotes/origin/main "$BASE"
mkdir -p "$R/docs" "$R/tools/tests"
printf 'clean\n' > "$R/docs/routing.md"
cat > "$R/tools/tests/routing-reader.test.sh" <<'SH'
#!/usr/bin/env bash
doc=docs/routing.md
cat "$doc" >/dev/null
printf 'reader\n' >> "$READER_LOG"
grep -Fxq broken "$doc" && exit 1
exit 0
SH
git -C "$R" add docs/routing.md tools/tests/routing-reader.test.sh
git -C "$R" commit -q -m document-reader
BASE="$(git -C "$R" rev-parse HEAD)"
git -C "$R" update-ref refs/remotes/origin/main "$BASE"
printf 'broken\n' > "$R/docs/routing.md"
git -C "$R" add docs/routing.md
git -C "$R" commit -q -m broken-document
READER_LOG="$TMP/reader-log"
export READER_LOG
branch="$("$REPO/skills/orch/scripts/resolve-base-branch" "$R")"
merge_base="$(git -C "$R" merge-base HEAD "origin/$branch")"
for base in "$merge_base" HEAD; do
  : > "$ROUTE_LOG"
  : > "$READER_LOG"
  RC=0
  OUT="$(cd "$R" && env -u DEV_VALIDATE_CMD -u DEV_VALIDATE_RANGE_CMD -u DEV_VALIDATE_SELECTION_CMD \
    PATH="$R/bin:$PATH" "$REPO/skills/orch/scripts/dev-validate-run" --worktree "$R" --validate-mode ci --base "$base" --poll 1 2>&1)" || RC=$?
  if [ "$base" = HEAD ]; then
    [ "$RC" -eq 0 ] && [ ! -s "$READER_LOG" ] && [[ $OUT == *validate=pass* ]] \
      && ok 'control: HEAD hides the committed document failure' || bad 'control: HEAD hides the committed document failure' "$OUT"
  else
    [ "$RC" -ne 0 ] && [ "$(cat "$READER_LOG")" = reader ] && grep -qF -- "--range $BASE" "$ROUTE_LOG" \
      && [[ $OUT == *validate=FAILING* ]] \
      && ok 'CI fallback reaches the failing committed document reader' || bad 'CI fallback reaches the failing committed document reader' "$OUT"
  fi
done

# Private settings regress each executable route. The same assertions redden.
for setting in DEV_VALIDATE_CMD DEV_VALIDATE_SELECTION_CMD; do
  cp "$REPO/kendex.settings.toml" "$R/kendex.settings.toml"
  sed "s/^$setting = .*/$setting = \"tools\/guard --full\"/" "$R/kendex.settings.toml" > "$TMP/settings"
  cmp -s "$R/kendex.settings.toml" "$TMP/settings" && { bad 'route control changes settings'; continue; }
  mv "$TMP/settings" "$R/kendex.settings.toml"
  route_command "$setting" ''
  [ "$RC" -eq 17 ] && grep -Fxq -- --full "$ROUTE_LOG" \
    && ok "control: restoring $setting to full rejects the route" || bad "control: restoring $setting to full rejects the route" "$OUT"
done
printf 'pass: %s fail: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
