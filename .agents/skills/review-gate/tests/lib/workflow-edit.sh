# shellcheck shell=bash
# Edit one adopted workflow and prove that the fixture reached its target.
workflow_edit() { # DIR EXPECTED_MATCHES MATCH_PATTERN SED_EXPRESSION [POSITION]
  local wf="$1/.github/workflows/review-gate-writer.yml" matches rc=0
  [ ! -L "$wf" ] || { printf 'fixture-error=workflow-symlink value=%q\n' "$wf" >&2; exit 2; }
  matches="$(grep -Ec -- "$3" "$wf")" || rc=$?
  [ "$rc" -le 1 ] && [ "$matches" = "$2" ] || {
    printf 'fixture-error=edit-matches value=%q\n' "$matches/$2:$3" >&2
    exit 2
  }
  if [ -n "${5:-}" ]; then
    local numbered target
    numbered="$(grep -nE -- "$3" "$wf")"
    target="$(awk -F: -v n="$5" 'NR == n { print $1 }' <<<"$numbered")"
    [ -n "$target" ] || { printf 'fixture-error=edit-position value=%q\n' "$5" >&2; exit 2; }
    sed -e "${target}{" -e "$4" -e '}' "$wf" >"$wf.new"
  else
    sed "$4" "$wf" >"$wf.new"
  fi
  rc=0
  cmp -s "$wf" "$wf.new" || rc=$?
  [ "$rc" -eq 1 ] || { printf 'fixture-error=edit-unchanged value=%q\n' "$rc" >&2; exit 2; }
  mv "$wf.new" "$wf"
  commit "$1"
}
