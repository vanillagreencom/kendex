#!/usr/bin/env bash
# The one markdown reader the orch doc lints use.
#
# Before this file every lint carried its own HTML-comment stripper, heading
# slicer and planted-control scaffolding, and each grew to pin the sentences of
# a workflow section. `review-bots.md` bans sentence-pinning lints on markdown:
# an editorial rephrase must not redden a suite while the contract holds. What
# a doc lint may pin is an IDENTIFIER — a heading, a state field, an inline
# code literal, a setting name — and the placement of one identifier relative
# to another.
#
# So the surface here is deliberately small, and it is the whole surface:
#
#   rule NAME FILE HEADING TOKEN...   one line under HEADING holds every TOKEN
#   absent NAME FILE HEADING RE SAMPLE  no line under HEADING matches RE
#   order NAME FILE RE_A RE_B         RE_A's first match precedes RE_B's
#   forbid NAME RE SAMPLE FILE...     no line in any FILE matches RE
#   forbid_fenced NAME RE SAMPLE F... no ```bash/```sh command line matches RE
#   permits[_fenced] NAME RE SAMPLE F a near-miss SAMPLE is not flagged
#   check NAME CMD...                 a bespoke predicate, for what the above
#                                     cannot express
#   section FILE HEADING              the section body, for a `check` predicate
#   line_has TEXT TOKEN...            one line of TEXT holds every TOKEN
#   fenced FILE                       "blockid<TAB>lineno<TAB>text" per fenced
#                                     command line
#
# One rule is one token set on one line. A rule that needs a second token set
# is a second rule, and a contract too subtle for that is uncovered here rather
# than covered in appearance.
#
# `md_report` closes every suite. It runs the planted control for every
# registered rule before printing: for each rule it deletes that rule's first
# token from the line the rule matched, re-evaluates EVERY rule against the
# mutated tree, and requires that exactly the mutated rule goes red. A rule
# whose control reddens a second rule is redundant with it; a rule whose
# control reddens nothing has no teeth. Both are failures.
#
# HTML comments are blanked before any read, line numbers preserved, so a rule
# commented out inside its own section — or by a `<!--` opened above the
# heading — reads as absent.

MD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$MD_LIB_DIR/.." && pwd)"
SKILL_DIR="$(cd "$TESTS_DIR/.." && pwd)"
SKILLS_ROOT="$(cd "$SKILL_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SKILLS_ROOT/.." && pwd)"
MD_TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$MD_TMP"' EXIT

PASS=0
FAIL=0
MD_RULES=()
MD_ORDERS=()
MD_FORBIDS=()
MD_ABSENTS=()
MD_PERMITS=0
MD_SEP=$'\037'

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

# _md_text FILE — the file with every HTML-comment span blanked, one output
# line per input line so a reported number is the real one.
_md_text() {
  awk '
    {
      s = $0; out = ""
      while (length(s) > 0) {
        if (inc) {
          p = index(s, "-->")
          if (p == 0) { s = "" } else { s = substr(s, p + 3); inc = 0 }
        } else {
          p = index(s, "<!--")
          if (p == 0) { out = out s; s = "" }
          else { out = out substr(s, 1, p - 1); s = substr(s, p + 4); inc = 1 }
        }
      }
      print out
    }
  ' "$1"
}

# _md_lines FILE HEADING — "lineno<TAB>text" for the body under the first
# `#`-heading line containing HEADING, ending at the next heading of the same
# or shallower depth. The heading line itself is not part of the body. An empty
# HEADING reads the whole file, headings excepted.
_md_lines() {
  _md_text "$1" | awk -v h="$2" '
    BEGIN { whole = (h == ""); on = whole }
    done_ { next }
    /^#+ / {
      if (whole) next
      d = 0
      while (substr($0, d + 1, 1) == "#") d++
      if (!on) { if (index($0, h) > 0) { on = 1; depth = d } ; next }
      if (d <= depth) { on = 0; done_ = 1; next }
    }
    on { printf "%d\t%s\n", NR, $0 }
  '
}

# section FILE HEADING — the section body as plain text.
section() { _md_lines "$1" "$2" | cut -f2-; }

# line_has TEXT TOKEN... — true iff one line of TEXT holds every TOKEN.
line_has() {
  local text="$1"
  shift
  local line tok ok
  while IFS= read -r line; do
    ok=1
    for tok in "$@"; do
      case "$line" in *"$tok"*) ;; *) ok=0; break ;; esac
    done
    [ "$ok" = 1 ] && return 0
  done <<<"$text"
  return 1
}

# fenced FILE — "blockid<TAB>lineno<TAB>text" per non-comment command line
# inside a ```bash or ```sh fence, blockid being the opening fence's line
# number so a caller can group by block. Prose, inline code, comment lines and
# other fences never appear.
fenced() {
  _md_text "$1" | awk '
    /^[[:space:]]*```/ {
      if (open) { open = 0; inf = 0; next }
      open = 1
      blockid = NR
      lang = $0
      sub(/^[[:space:]]*```[[:space:]]*/, "", lang)
      sub(/[[:space:]].*$/, "", lang)
      inf = (lang == "bash" || lang == "sh")
      next
    }
    inf {
      t = $0
      sub(/^[[:space:]]+/, "", t)
      if (t == "" || substr(t, 1, 1) == "#") next
      printf "%d\t%d\t%s\n", blockid, NR, $0
    }
  '
}

# _md_match FILE HEADING TOKEN... — the line number of the first body line
# holding every TOKEN, or empty.
_md_match() {
  local file="$1" heading="$2"
  shift 2
  local n line tok ok
  while IFS=$'\t' read -r n line; do
    ok=1
    for tok in "$@"; do
      case "$line" in *"$tok"*) ;; *) ok=0; break ;; esac
    done
    if [ "$ok" = 1 ]; then
      printf '%s\n' "$n"
      return 0
    fi
  done < <(_md_lines "$file" "$heading")
  return 1
}

# _md_indices COUNT — 0..COUNT-1, or nothing. `${!arr[@]}` on an empty array is
# unbound under `set -u` in Bash 3.2, which `SKILL.md` § System dependencies
# declares, and a suite registering one rule form leaves three arrays empty.
_md_indices() {
  local n="$1" i=0
  while [ "$i" -lt "$n" ]; do
    printf '%s\n' "$i"
    i=$((i + 1))
  done
}

# _md_fields REC — splits a registry record into the MD_F array.
_md_fields() {
  local old="$IFS"
  IFS="$MD_SEP"
  read -r -a MD_F <<<"$1"
  IFS="$old"
}

# rule NAME FILE HEADING TOKEN...
rule() {
  local name="$1" file="$2" heading="$3"
  shift 3
  local rec="$name$MD_SEP$file$MD_SEP$heading" t
  for t in "$@"; do rec="$rec$MD_SEP$t"; done
  MD_RULES+=("$rec")
  if [ -n "$(_md_match "$file" "$heading" "$@")" ]; then
    pass "$name"
  else
    fail "$name — no line under '$heading' in ${file##*/} holds: $*"
  fi
}

# _md_holds REC ORIG SCRATCH — re-evaluates one rule, reading SCRATCH in place
# of ORIG.
_md_holds() {
  _md_fields "$1"
  local f="${MD_F[1]}"
  [ "$f" = "$2" ] && f="$3"
  [ -n "$(_md_match "$f" "${MD_F[2]}" "${MD_F[@]:3}")" ]
}

# order NAME FILE RE_A RE_B — A's first match precedes B's. Its control is the
# reversed comparison: if A really precedes B, B preceding A must be false.
order() {
  MD_ORDERS+=("$1$MD_SEP$2$MD_SEP$3$MD_SEP$4")
  local a b
  a="$(_md_first "$2" "$3")"
  b="$(_md_first "$2" "$4")"
  if [ -z "$a" ] || [ -z "$b" ]; then
    fail "$1 — ${2##*/} carries no match for /$3/ or /$4/"
  elif [ "$a" -lt "$b" ]; then
    pass "$1"
  else
    fail "$1 — /$3/ is at line $a, behind /$4/ at line $b"
  fi
}

# _md_first FILE RE — the first line number matching RE, or empty. Reads its
# input to the end: an early `exit` would SIGPIPE the stripper feeding it, and
# under `pipefail` that 141 reads as a failed check.
_md_first() {
  local out
  out="$(_md_text "$1" | grep -nE -e "$2" || true)"
  [ -n "$out" ] || return 0
  printf '%s\n' "${out%%$'\n'*}" | cut -d: -f1
}

# _md_head_line FILE HEADING — the line number of the heading itself, or of the
# file's first heading when HEADING is empty. The empty case is spelled out
# rather than left to `index(s, "")`, whose result differs between awks.
_md_head_line() {
  md_head="$2" awk '
    BEGIN { h = ENVIRON["md_head"]; whole = (h == "") }
    /^#+ / && !n && (whole || index($0, h) > 0) { n = NR }
    END { if (n) print n }
  ' <(_md_text "$1")
}

# absent NAME FILE HEADING RE SAMPLE — no line under HEADING matches RE. Its
# control inserts SAMPLE directly under the heading and requires a flag.
absent() {
  MD_ABSENTS+=("$1$MD_SEP$2$MD_SEP$3$MD_SEP$4$MD_SEP$5")
  local hit
  hit="$(section "$2" "$3" | grep -nE -e "$4" || true)"
  if [ -z "$hit" ]; then
    pass "$1"
  else
    fail "$1"
    printf '%s\n' "$hit" | sed 's/^/          /'
  fi
}

# _md_offenders RE FILE... — "file:line: text" per matching line.
_md_offenders() {
  local re="$1" f
  shift
  for f in "$@"; do
    _md_text "$f" | grep -nE -e "$re" | sed "s|^|${f#$REPO_ROOT/}:|" || true
  done
}

# forbid NAME RE SAMPLE FILE... — no line in any FILE matches RE. SAMPLE is a
# line that must match, appended to a scratch copy by the control.
forbid() {
  local name="$1" re="$2" sample="$3"
  shift 3
  MD_FORBIDS+=("$name$MD_SEP$re$MD_SEP$sample${MD_SEP}line$MD_SEP$1")
  local out
  out="$(_md_offenders "$re" "$@")"
  if [ -z "$out" ]; then
    pass "$name"
  else
    fail "$name"
    printf '%s\n' "$out" | sed 's/^/          /'
  fi
}

# forbid_fenced NAME RE SAMPLE FILE... — the same, over fenced command lines.
# RE is matched against the command text alone; the line number is reported.
_md_fenced_hits() {
  local re="$1" f
  shift
  for f in "$@"; do
    fenced "$f" | md_re="$re" awk -F'\t' -v p="${f#$REPO_ROOT/}" \
      'BEGIN { re = ENVIRON["md_re"] }
       { t = $0; sub(/^[0-9]+\t[0-9]+\t/, "", t); if (t ~ re) printf "%s:%s: %s\n", p, $2, t }'
  done
}

forbid_fenced() {
  local name="$1" re="$2" sample="$3"
  shift 3
  MD_FORBIDS+=("$name$MD_SEP$re$MD_SEP$sample${MD_SEP}fenced$MD_SEP$1")
  local out
  out="$(_md_fenced_hits "$re" "$@")"
  if [ -z "$out" ]; then
    pass "$name"
  else
    fail "$name"
    printf '%s\n' "$out" | sed 's/^/          /'
  fi
}

# permits NAME RE SAMPLE FILE — the near-miss half of a `forbid`: SAMPLE
# appended to a clean FILE must NOT be flagged. `mode` is line or fenced.
_md_permits() {
  local name="$1" re="$2" sample="$3" file="$4" mode="$5"
  MD_PERMITS=$((MD_PERMITS + 1))
  local scratch="$MD_TMP/permit-$MD_PERMITS.md" hit
  cp "$file" "$scratch"
  if [ "$mode" = fenced ]; then
    printf '\n```bash\n%s\n```\n' "$sample" >>"$scratch"
    hit="$(_md_fenced_hits "$re" "$scratch")"
  else
    printf '\n%s\n' "$sample" >>"$scratch"
    hit="$(_md_offenders "$re" "$scratch")"
  fi
  if [ -z "$hit" ]; then pass "$name"; else fail "$name — flagged: $hit"; fi
}
permits() { _md_permits "$1" "$2" "$3" "$4" line; }
permits_fenced() { _md_permits "$1" "$2" "$3" "$4" fenced; }

# check NAME CMD... — a bespoke predicate, for a contract the four rule forms
# above cannot express. It carries no automatic control: a suite using it owns
# proving its teeth.
check() {
  local name="$1"
  shift
  if "$@"; then pass "$name"; else fail "$name"; fi
}

# _md_strike FILE LINE TOKEN SCRATCH — copies FILE to SCRATCH with EVERY
# occurrence of TOKEN deleted from line LINE. Every occurrence, not the first:
# a rule line naming its token twice would otherwise survive its own control
# and read as having teeth. A token the section repeats on a SECOND line
# survives, and the control then reports that the rule reddened nothing — which
# is the right answer: pin the line by something only that line carries.
_md_strike() {
  md_tok="$3" awk -v lo="$2" -v hi="$2" '
    BEGIN { tok = ENVIRON["md_tok"]; n = length(tok) }
    NR >= lo && NR <= hi {
      out = ""
      while ((i = index($0, tok)) > 0) {
        out = out substr($0, 1, i - 1)
        $0 = substr($0, i + n)
      }
      $0 = out $0
    }
    { print }
  ' "$1" >"$4"
}

# _md_controls — the planted control for every registered rule.
_md_controls() {
  local i j rec scratch ln reddened victim
  for i in $(_md_indices "${#MD_RULES[@]}"); do
    rec="${MD_RULES[$i]}"
    _md_fields "$rec"
    local name="${MD_F[0]}" file="${MD_F[1]}"
    ln="$(_md_match "$file" "${MD_F[2]}" "${MD_F[@]:3}")"
    # No match: the rule itself already reported FAIL above, and a control over
    # a line that is not there would only repeat it.
    if [ -z "$ln" ]; then continue; fi
    scratch="$MD_TMP/rule-$i.md"
    _md_strike "$file" "$ln" "${MD_F[3]}" "$scratch"
    if cmp -s "$file" "$scratch"; then
      fail "control for '$name' planted nothing — '${MD_F[3]}' is not on line $ln"
      continue
    fi
    reddened=""
    for j in $(_md_indices "${#MD_RULES[@]}"); do
      if _md_holds "${MD_RULES[$j]}" "$file" "$scratch"; then :; else
        _md_fields "${MD_RULES[$j]}"
        reddened="$reddened ${MD_F[0]}"
      fi
    done
    victim=" $name"
    if [ "$reddened" = "$victim" ]; then
      pass "control: '$name' goes red alone when its token is dropped"
    elif [ -z "$reddened" ]; then
      fail "control for '$name' reddened nothing — the rule has no teeth"
    else
      fail "control for '$name' reddened:$reddened — the rules overlap"
    fi
  done

  for i in $(_md_indices "${#MD_ORDERS[@]}"); do
    _md_fields "${MD_ORDERS[$i]}"
    local oname="${MD_F[0]}" ofile="${MD_F[1]}" a b ca cb
    a="$(_md_first "$ofile" "${MD_F[2]}")"
    b="$(_md_first "$ofile" "${MD_F[3]}")"
    if [ -z "$a" ] || [ -z "$b" ]; then continue; fi
    scratch="$MD_TMP/order-$i.md"
    awk -v x="$a" -v y="$b" '
      { l[NR] = $0 }
      END { t = l[x]; l[x] = l[y]; l[y] = t; for (k = 1; k <= NR; k++) print l[k] }
    ' "$ofile" >"$scratch"
    ca="$(_md_first "$scratch" "${MD_F[2]}")"
    cb="$(_md_first "$scratch" "${MD_F[3]}")"
    if [ -n "$ca" ] && [ -n "$cb" ] && [ "$cb" -lt "$ca" ]; then
      pass "control: '$oname' goes red when the two headings swap places"
    else
      fail "control for '$oname' — swapping the headings did not reverse the order"
    fi
  done

  for i in $(_md_indices "${#MD_ABSENTS[@]}"); do
    _md_fields "${MD_ABSENTS[$i]}"
    local aname="${MD_F[0]}" afile="${MD_F[1]}" ahead="${MD_F[2]}" are="${MD_F[3]}"
    local asample="${MD_F[4]}" hl
    hl="$(_md_head_line "$afile" "$ahead")"
    scratch="$MD_TMP/absent-$i.md"
    if [ -z "$hl" ]; then
      fail "control for '$aname' — ${afile##*/} carries no heading '$ahead'"
      continue
    fi
    awk -v ln="$hl" -v s="$asample" 'NR == ln { print; print ""; print s; next } { print }' \
      "$afile" >"$scratch"
    if [ -n "$(section "$scratch" "$ahead" | grep -E -e "$are" || true)" ]; then
      pass "control: '$aname' flags its sample"
    else
      fail "control for '$aname' — the sample under '$ahead' is not flagged"
    fi
  done

  for i in $(_md_indices "${#MD_FORBIDS[@]}"); do
    _md_fields "${MD_FORBIDS[$i]}"
    local fname="${MD_F[0]}" fre="${MD_F[1]}" fsample="${MD_F[2]}" mode="${MD_F[3]}"
    local base="${MD_F[4]}"
    scratch="$MD_TMP/forbid-$i.md"
    cp "$base" "$scratch"
    if [ "$mode" = fenced ]; then
      printf '\n```bash\n%s\n```\n' "$fsample" >>"$scratch"
      if [ -n "$(_md_fenced_hits "$fre" "$scratch")" ]; then
        pass "control: '$fname' flags its sample"
      else
        fail "control for '$fname' — the sample is not flagged"
      fi
    else
      printf '\n%s\n' "$fsample" >>"$scratch"
      if [ -n "$(_md_offenders "$fre" "$scratch")" ]; then
        pass "control: '$fname' flags its sample"
      else
        fail "control for '$fname' — the sample is not flagged"
      fi
    fi
  done
}

# md_report — controls, then the tally. Every suite ends with this.
md_report() {
  _md_controls
  echo
  printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
}
