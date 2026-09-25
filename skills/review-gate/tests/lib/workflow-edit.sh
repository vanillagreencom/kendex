# shellcheck shell=bash
# Edit one sandbox file and prove that the fixture reached its target. The
# caller commits; workflow_edit, the adopted workflow's edit, commits itself.
file_edit() { # DIR PATH EXPECTED_MATCHES MATCH_PATTERN SED_EXPRESSION [POSITION]
  local f="$1/$2" matches rc=0
  [ ! -L "$f" ] || { printf 'fixture-error=edit-symlink value=%q\n' "$f" >&2; exit 2; }
  matches="$(grep -Ec -- "$4" "$f")" || rc=$?
  [ "$rc" -le 1 ] && [ "$matches" = "$3" ] || {
    printf 'fixture-error=edit-matches value=%q\n' "$matches/$3:$4" >&2
    exit 2
  }
  if [ -n "${6:-}" ]; then
    local numbered target
    numbered="$(grep -nE -- "$4" "$f")"
    target="$(awk -F: -v n="$6" 'NR == n { print $1 }' <<<"$numbered")"
    [ -n "$target" ] || { printf 'fixture-error=edit-position value=%q\n' "$6" >&2; exit 2; }
    sed -e "${target}{" -e "$5" -e '}' "$f" >"$f.new"
  else
    sed "$5" "$f" >"$f.new"
  fi
  rc=0
  cmp -s "$f" "$f.new" || rc=$?
  [ "$rc" -eq 1 ] || { printf 'fixture-error=edit-unchanged value=%q\n' "$rc" >&2; exit 2; }
  mv "$f.new" "$f"
}

workflow_edit() { # DIR EXPECTED_MATCHES MATCH_PATTERN SED_EXPRESSION [POSITION]
  file_edit "$1" .github/workflows/review-gate-writer.yml "$2" "$3" "$4" "${5:-}"
  commit "$1"
}
