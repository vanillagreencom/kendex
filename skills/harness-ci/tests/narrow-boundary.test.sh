#!/usr/bin/env bash
# orch's narrow-change.conf boundary group against what the micro-tier
# measurement reads and runs.
#
# Each measurement script states its own boundary as `# measures-with:` lines
# naming catalog paths: the files whose edit changes the range measured, the
# settings the measurement reads, or the ceilings it compares against. The
# group the conf opens with `# [boundary]` must be exactly that union, read
# both ways: a declared path no boundary glob covers, a boundary glob no
# declared path backs, and a boundary glob that also covers a catalog file no
# declaration names, are each drift. A declared file's `source` and `.`
# lines are read too, each resolved to one catalog path whatever its
# spelling: a file one of them loads that no declaration names, a path
# naming no catalog file, and a line the resolver cannot bring to one path
# are each drift. The static read sees the libraries; the declaration
# carries what reaches execution another way, such as the base resolver
# branch-size-check passes as an argument.
#
# Every drift line starts with a key and the path or glob it names.
set -euo pipefail
# shellcheck source=lib/sandbox.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/sandbox.sh"

CATALOG="$(cd "$TEST_DIR/../.." && pwd)"

# The measurement scripts under CATALOG: every file under a package's
# scripts/ carrying a `# measures-with:` line, as catalog-relative paths.
measurement_scripts() { # CATALOG
  (cd -- "$1" && grep -rlE '^# measures-with: ' -- */scripts 2>/dev/null | sort) || true
}

# The union of every measurement script's declared boundary.
boundary_declared() { # CATALOG
  local script
  while IFS= read -r script; do
    [ -n "$script" ] || continue
    sed -n 's/^# measures-with: //p' "$1/$script"
  done <<<"$(measurement_scripts "$1")"
}

# The globs of the conf's boundary group: the `path` lines after its
# `# [boundary]` line, up to the first blank line.
boundary_globs() { # CONF
  awk '/^# \[boundary\]/ { group = 1; next } group && /^$/ { exit } group && /^path / { print substr($0, 6) }' "$1"
}

# Every `source` or `.` in command position is resolved to one catalog path,
# whatever the spelling of its word: quoted, split-quoted, unquoted, braced,
# relative or absolute. The word is read as the shell reads it, quotes
# removed. It resolves when it is a literal path with no expansion, or a
# directory variable the file itself assigns followed by a literal path. A
# variable the file owns is one it assigns its own directory
# (`$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)`, or with `$0`), or a
# literal path under such a variable. A relative path resolves against the
# file's own catalog directory, an absolute one only where it lies under the
# catalog, and `..` is folded either way. A word that cannot be brought to one
# catalog path — a variable the file does not own, a command substitution, a
# variable alone — is never skipped: it is reported naming the line.
# Single-quoted text, heredoc bodies and comments are read as text, never as
# a loader. The one loader the walk admits unresolved is SOURCE_EXEMPTION
# below, matched on the file and the whole line.
#
# kendex-env.sh reads the project's settings files, which are no catalog
# file, through a variable naming each in turn.
SOURCE_EXEMPTION='skills/orch/scripts/lib/kendex-env.sh|source "$file" >&2'

# One line per loader in FILE: `path <catalog path>` where its word
# resolves, `unsupported <line number>` where it does not.
sourced_paths() { # CATALOG CATALOG_PATH FILE
  local exempt=""
  [ "${SOURCE_EXEMPTION%%|*}" != "$2" ] || exempt="${SOURCE_EXEMPTION#*|}"
  awk -v root="$1" -v dir="${2%/*}" -v exempt="$exempt" '
    function norm(p,   n, i, parts, out, k, res) {
      n = split(p, parts, "/"); k = 0
      for (i = 1; i <= n; i++) {
        if (parts[i] == "" || parts[i] == ".") continue
        if (parts[i] == "..") { if (k > 0) k--; continue }
        out[++k] = parts[i]
      }
      res = ""
      for (i = 1; i <= k; i++) res = res (i > 1 ? "/" : "") out[i]
      return res
    }
    # The line as the loader search reads it, the same length as the line:
    # single-quoted text blanked and a comment cut. The quoting state is
    # carried to the next line as a stack, because a double-quoted `$(...)`
    # opens a context of its own whose quotes nest inside the outer ones.
    function code(line,   i, c, prev, out, top) {
      out = ""; prev = " "
      if (depth == 0) st[depth = 1] = "N"
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1); top = st[depth]
        if (insq) { if (c == "\047") { insq = 0; out = out c } else out = out "\001"; prev = c; continue }
        if (c == "\\") { out = out substr(line, i, 2); i++; prev = "x"; continue }
        if (c == "$" && substr(line, i + 1, 1) == "(") { st[++depth] = "N"; out = out "$("; i++; prev = "("; continue }
        if (top == "D") { if (c == "\"") depth--; out = out c; prev = c; continue }
        if (c == "\047") { insq = 1; out = out c; prev = c; continue }
        if (c == "\"") { st[++depth] = "D"; out = out c; prev = c; continue }
        if (c == "(") st[++depth] = "N"
        if (c == ")" && depth > 1) depth--
        if (c == "#" && prev ~ /[[:space:](&;|]/) break
        out = out c; prev = c
      }
      return out
    }
    # The shell word at the start of s, quotes removed; "" with bad set
    # where it holds an expansion no literal path can stand for.
    function word(s,   i, c, w, q) {
      w = ""; bad = 0; q = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (q == "\047") { if (c == "\047") q = ""; else { if (c == "$") bad = 1; w = w c }; continue }
        if (c == "\\") { w = w substr(s, i + 1, 1); i++; continue }
        if (c == "`" || (c == "$" && substr(s, i + 1, 1) == "(")) { bad = 1; w = w c; continue }
        if (q == "\"") { if (c == "\"") q = ""; else w = w c; continue }
        if (c == "\047" || c == "\"") { q = c; continue }
        if (c ~ /[[:space:]&;)|<>]/) break
        w = w c
      }
      return w
    }
    function resolve(w,   ref, rest) {
      if (bad || w == "") return ""
      if (w ~ /^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?\/[^$]+$/) {
        ref = w; sub(/^\$\{?/, "", ref); sub(/[}\/].*/, "", ref)
        rest = w; sub(/^[^\/]*/, "", rest)
        return (ref in dirs) ? norm(dirs[ref] rest) : ""
      }
      if (index(w, "$") > 0) return ""
      if (substr(w, 1, 1) != "/") return norm(dir "/" w)
      if (index(w, root "/") == 1) return norm("skills/" substr(w, length(root) + 2))
      return ""
    }
    heredoc != "" {
      t = $0; if (strip) sub(/^\t+/, "", t)
      if (t == heredoc) heredoc = ""
      next
    }
    {
      text = code($0)
      if (!insq && st[depth] != "D" && match(text, /<<-?[[:space:]]*["\047]?[A-Za-z_][A-Za-z0-9_]*/) && substr(text, RSTART, 3) != "<<<") {
        tag = substr(text, RSTART, RLENGTH); strip = (tag ~ /^<<-/)
        sub(/^<<-?[[:space:]]*["\047]?/, "", tag); heredoc = tag
      }
    }
    text ~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*="\$\(cd "\$\(dirname "(\$\{BASH_SOURCE\[0\]\}|\$0)"\)" && pwd\)"/ {
      name = text; sub(/^[[:space:]]*/, "", name); sub(/=.*/, "", name)
      dirs[name] = dir
      next
    }
    text ~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*="\$[A-Za-z_][A-Za-z0-9_]*\/[^"$]*"[[:space:]]*$/ {
      name = text; sub(/^[[:space:]]*/, "", name); sub(/=.*/, "", name)
      ref = text; sub(/^[^$]*\$/, "", ref); rest = ref
      sub(/\/.*/, "", ref); sub(/^[A-Za-z0-9_]*/, "", rest); sub(/"[[:space:]]*$/, "", rest)
      if (ref in dirs) dirs[name] = norm(dirs[ref] rest)
      next
    }
    match(text, /(^|[!(&{;|]|[[:space:]](if|then|do|else|while|until))[[:space:]]*(source|\.)([[:space:]]|$)/) {
      whole = $0; sub(/^[[:space:]]+/, "", whole); sub(/[[:space:]]+$/, "", whole)
      if (exempt != "" && whole == exempt) next
      rest = substr($0, RSTART + RLENGTH)
      sub(/^[[:space:]]+/, "", rest)
      path = resolve(word(rest))
      if (path != "") print "path " path
      else print "unsupported " NR
    }' "$3"
}

boundary_drift() { # CATALOG CONF
  local catalog="$1" conf="$2" declared globs files path glob kind loaded hit
  declared="$(boundary_declared "$catalog" | sort -u)"
  globs="$(boundary_globs "$conf")"
  # Without either side there is nothing to hold the other to, so each
  # absence is the one line reported.
  if [ -z "$declared" ]; then
    echo "no-declaration catalog=$catalog"
    return
  fi
  if [ -z "$globs" ]; then
    echo "no-boundary-group conf=$conf"
    return
  fi
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if [ ! -f "$catalog/${path#skills/}" ]; then
      echo "missing path=$path"
      continue
    fi
    while IFS=' ' read -r kind loaded; do
      case "$kind" in
        '') ;;
        path)
          if [ ! -f "$catalog/${loaded#skills/}" ]; then
            echo "unresolved-source file=$path source=$loaded"
          elif ! grep -qxF -- "$loaded" <<<"$declared"; then
            echo "undeclared-source file=$path source=$loaded"
          fi ;;
        unsupported) echo "unsupported-source file=$path line=$loaded" ;;
        *) echo "reader-broken file=$path kind=$kind" ;;
      esac
    done <<<"$(sourced_paths "$catalog" "$path" "$catalog/${path#skills/}")"
    hit=false
    while IFS= read -r glob; do
      [ -n "$glob" ] || continue
      # shellcheck disable=SC2254
      case "$path" in $glob) hit=true; break ;; esac
    done <<<"$globs"
    [ "$hit" = true ] || echo "uncovered path=$path"
  done <<<"$declared"
  files="$(cd -- "$catalog" && find . -type f | sed 's|^\./|skills/|' | sort)"
  while IFS= read -r glob; do
    [ -n "$glob" ] || continue
    hit=false
    while IFS= read -r path; do
      # shellcheck disable=SC2254
      case "$path" in $glob) hit=true; break ;; esac
    done <<<"$declared"
    if [ "$hit" = false ]; then
      echo "unbacked glob=$glob"
      continue
    fi
    # The first catalog file the glob covers that no declaration names.
    while IFS= read -r path; do
      # shellcheck disable=SC2254
      case "$path" in $glob) ;; *) continue ;; esac
      grep -qxF -- "$path" <<<"$declared" && continue
      echo "wider glob=$glob path=$path"
      break
    done <<<"$files"
  done <<<"$globs"
}

REAL_CONF="$CATALOG/orch/references/narrow-change.conf"

# The extractor's floor, with the two members it must find: a reader finding
# neither has broken, not found a tree with no measurement.
scripts="$(measurement_scripts "$CATALOG")"
assert_eq "the measurement scripts are the two that measure" \
  "harness-ci/scripts/change-class
orch/scripts/branch-size-check" "$scripts"

assert_eq "the boundary group agrees with the measurement's declarations" "" \
  "$(boundary_drift "$CATALOG" "$REAL_CONF")"

# The derived set carries what no invocation-syntax walk reaches, and leaves
# out what the measurement runs for a reason outside the rule.
declared="$(boundary_declared "$CATALOG")"
assert_eq "the base resolver branch-size-check passes as an argument is carried" "1" \
  "$(grep -cxF 'skills/orch/scripts/resolve-base-branch' <<<"$declared")"
assert_eq "the Linear CLI read for the allowance is not" "0" \
  "$(grep -cxF 'skills/linear/scripts/linear.sh' <<<"$declared" || true)"

# One planted drift per rule, each on a fresh copy of the two packages, each
# answering exactly the line that rule prints. @CATALOG@ and @CONF@ stand for
# the copy's catalog and conf, @LAST_LINE@ for the line an edit appended.
# label | the edit | the drift expected
fixture_rows=0
while IFS='|' read -r label edit expected; do
  fixture_rows=$((fixture_rows + 1))
  fixture="$SANDBOX/catalog-$fixture_rows"
  mkdir -p "$fixture/orch/references" "$fixture/harness-ci"
  cp -R "$CATALOG/orch/scripts" "$fixture/orch/scripts"
  cp "$REAL_CONF" "$fixture/orch/references/narrow-change.conf"
  cp -R "$CATALOG/harness-ci/scripts" "$fixture/harness-ci/scripts"
  conf="$fixture/orch/references/narrow-change.conf"
  measured="$fixture/orch/scripts/branch-size-check"
  case "$edit" in
    declare-extra)
      printf '%s\n' '# measures-with: skills/orch/scripts/lib/lane-cap.sh' >>"$measured" ;;
    drop-conf-row)
      grep -vxF 'path *skills/orch/scripts/resolve-base-branch' "$conf" >"$conf.new"
      mv "$conf.new" "$conf" ;;
    add-conf-row)
      awk '{ print } /^path \*skills\/orch\/scripts\/branch-size-check$/ { print "path *skills/orch/scripts/lanes" }' \
        "$conf" >"$conf.new"
      mv "$conf.new" "$conf" ;;
    source-other-skill)
      # Another skill's library of the same name as a declared one: a
      # check matching the name alone takes it for orch's.
      mkdir -p "$fixture/linear/scripts/lib"
      cp "$CATALOG/orch/scripts/lib/kendex-env.sh" "$fixture/linear/scripts/lib/kendex-env.sh"
      printf '%s\n' 'source "$SCRIPT_DIR/../../linear/scripts/lib/kendex-env.sh"' >>"$measured" ;;
    source-nowhere)
      printf '%s\n' 'source "$SCRIPT_DIR/lib/not-there.sh"' >>"$measured" ;;
    source-unknown-variable)
      printf '%s\n' 'source "$OTHER_SKILL_LIB/kendex-env.sh"' >>"$measured" ;;
    source-spelled-*)
      # One new dependency, lib/lane-relaunch.sh, in the spelling the row
      # names; each must resolve to that one catalog path.
      case "$edit" in
        source-spelled-quoted) spelled='source "$SCRIPT_DIR/lib/lane-relaunch.sh"' ;;
        source-spelled-split-quoted) spelled='source "$SCRIPT_DIR"/lib/lane-relaunch.sh' ;;
        source-spelled-unquoted) spelled='true; . $SCRIPT_DIR/lib/lane-relaunch.sh' ;;
        source-spelled-braced) spelled='source ${SCRIPT_DIR}/lib/lane-relaunch.sh' ;;
        source-spelled-relative) spelled='source lib/lane-relaunch.sh' ;;
        source-spelled-absolute) spelled="source $fixture/orch/scripts/lib/lane-relaunch.sh" ;;
        *) echo "unknown spelling $edit" >&2; exit 1 ;;
      esac
      printf '%s\n' "$spelled" >>"$measured" ;;
    source-substitution)
      printf '%s\n' 'source "$(dirname "$0")/lib/lane-relaunch.sh"' >>"$measured" ;;
    source-bare-variable)
      printf '%s\n' 'source "$file" >&2' >>"$measured" ;;
    declare-missing)
      printf '%s\n' '# measures-with: skills/orch/scripts/gone' >>"$measured"
      awk '{ print } /^path \*skills\/orch\/scripts\/branch-size-check$/ { print "path *skills/orch/scripts/gone" }' \
        "$conf" >"$conf.new"
      mv "$conf.new" "$conf" ;;
    no-declaration)
      for declaring in "$measured" "$fixture/harness-ci/scripts/change-class"; do
        grep -v '^# measures-with: ' "$declaring" >"$declaring.new"
        mv "$declaring.new" "$declaring"
      done ;;
    widen-row)
      cp "$measured" "$measured.orig"
      sed 's|^path \*skills/orch/scripts/branch-size-check$|path *skills/orch/scripts/branch-size-check*|' \
        "$conf" >"$conf.new"
      mv "$conf.new" "$conf" ;;
    no-boundary-group)
      grep -v '^# \[boundary\]' "$conf" >"$conf.new"
      mv "$conf.new" "$conf" ;;
    *) echo "unknown edit $edit" >&2; exit 1 ;;
  esac
  assert_eq "the control's edit changed its file" "changed" \
    "$(if cmp -s "$conf" "$REAL_CONF" && cmp -s "$measured" "$CATALOG/orch/scripts/branch-size-check"; then echo same; else echo changed; fi)"
  expected="${expected//@CATALOG@/$fixture}"
  expected="${expected//@CONF@/$conf}"
  expected="${expected//@LAST_LINE@/$(grep -c '' "$measured")}"
  assert_eq "$label" "$expected" "$(boundary_drift "$fixture" "$conf")"
done <<'FIXTURES'
a dependency declared without its conf row is named|declare-extra|uncovered path=skills/orch/scripts/lib/lane-cap.sh
a conf row dropped while the declaration still carries it is named|drop-conf-row|uncovered path=skills/orch/scripts/resolve-base-branch
a boundary row no declaration backs is named|add-conf-row|unbacked glob=*skills/orch/scripts/lanes
a library sourced without a declaration is named, spelled quoted|source-spelled-quoted|undeclared-source file=skills/orch/scripts/branch-size-check source=skills/orch/scripts/lib/lane-relaunch.sh
a library sourced without a declaration is named, spelled split-quoted|source-spelled-split-quoted|undeclared-source file=skills/orch/scripts/branch-size-check source=skills/orch/scripts/lib/lane-relaunch.sh
a library sourced without a declaration is named, spelled unquoted|source-spelled-unquoted|undeclared-source file=skills/orch/scripts/branch-size-check source=skills/orch/scripts/lib/lane-relaunch.sh
a library sourced without a declaration is named, spelled braced|source-spelled-braced|undeclared-source file=skills/orch/scripts/branch-size-check source=skills/orch/scripts/lib/lane-relaunch.sh
a library sourced without a declaration is named, spelled relative|source-spelled-relative|undeclared-source file=skills/orch/scripts/branch-size-check source=skills/orch/scripts/lib/lane-relaunch.sh
a library sourced without a declaration is named, spelled absolute|source-spelled-absolute|undeclared-source file=skills/orch/scripts/branch-size-check source=skills/orch/scripts/lib/lane-relaunch.sh
another skill's library of the same name is named|source-other-skill|undeclared-source file=skills/orch/scripts/branch-size-check source=skills/linear/scripts/lib/kendex-env.sh
a library that is not in the catalog is named|source-nowhere|unresolved-source file=skills/orch/scripts/branch-size-check source=skills/orch/scripts/lib/not-there.sh
a library under a variable the script does not own is reported|source-unknown-variable|unsupported-source file=skills/orch/scripts/branch-size-check line=@LAST_LINE@
a loader through a command substitution is reported|source-substitution|unsupported-source file=skills/orch/scripts/branch-size-check line=@LAST_LINE@
a bare variable no exemption names is reported|source-bare-variable|unsupported-source file=skills/orch/scripts/branch-size-check line=@LAST_LINE@
a declared file that is not there is named|declare-missing|missing path=skills/orch/scripts/gone
a catalog whose scripts declare nothing is named|no-declaration|no-declaration catalog=@CATALOG@
a conf with no boundary group is named|no-boundary-group|no-boundary-group conf=@CONF@
a boundary row covering a file no declaration names is named|widen-row|wider glob=*skills/orch/scripts/branch-size-check* path=skills/orch/scripts/branch-size-check.orig
FIXTURES
require_rows narrow-boundary-fixtures "$fixture_rows"

report narrow-boundary
