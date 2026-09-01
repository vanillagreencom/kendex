#!/usr/bin/env bash
# The one markdown reader the doc lints share. It lives under orch because
# orch's lints were its first callers, not because they are its only ones: a
# suite in any skill may source it, and `skills/dev/tests` does.
#
# Before this file every lint carried its own HTML-comment stripper, heading
# slicer and planted-control scaffolding, and each grew to pin the sentences of
# a workflow section. `review-bots.md` bans sentence-pinning lints on markdown:
# an editorial rephrase must not redden a suite while the contract holds. What
# a doc lint may pin is an IDENTIFIER — a heading, a state field, an inline
# code literal, a setting name — and the placement of one identifier relative
# to another.
#
# The rule forms are deliberately few, and these are all of them:
#
#   rule NAME FILE HEADING TOKEN...   one line under HEADING holds every TOKEN
#   rule_fenced NAME FILE HEADING T…  the same, but the line must be a command
#                                     inside a ```bash/```sh fence
#   absent[_i] NAME FILE HEADING RE SAMPLE
#                                     no line under HEADING matches RE
#   order NAME FILE RE_A RE_B         RE_A's first match precedes RE_B's
#   forbid NAME RE SAMPLE FILE...     no line in any FILE matches RE
#   forbid_fenced NAME RE SAMPLE F... no ```bash/```sh command line matches RE
#   permits[_fenced] NAME RE PROBE SAMPLE FILE
#                                     SAMPLE is not flagged where PROBE is
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
# NO TRANSCRIBED VALUES, in this file or in any suite's header. That covers two
# kinds, and the second is the one a sweep for counts misses: a count OF the
# tree — suites, rules, files, lines — and a value copied OUT of another file,
# a CI timeout or a setting's default. Both go stale silently, because nothing
# rechecks a comment. Give the command that derives it and the scope it runs
# over, or pin the other file's line with a `rule` so the two fail together.
# Inherent counts stay: "the two state buckets" names the contract itself, and
# no change to the tree can make it wrong.
#
# A suite also gets, beyond the rule forms: `pass` and `fail` for a verdict it
# reaches itself, `md_report` to close, the path variables SKILL_DIR,
# SKILLS_ROOT, REPO_ROOT and MD_LIB_DIR, and MD_TMP for scratch. Nothing else
# here is a suite's to call.
#
# THOSE PATHS ARE RESOLVED FROM THIS FILE, so TESTS_DIR, SKILL_DIR and
# SKILLS_ROOT all name orch whoever sourced it. A caller outside orch must set
# its own SKILL_DIR after the `source` line, or a rule written in the house
# style, `"$SKILL_DIR/SKILL.md"`, reads orch's document and answers about the
# wrong file. REPO_ROOT and MD_LIB_DIR are the same for every caller.
#
# A suite must NOT install its own EXIT trap. Sourcing this file installs one
# that removes MD_TMP, and `trap ... EXIT` replaces rather than adds, so a
# suite setting its own leaks a mktemp directory per run — no symptom but
# growth under TMPDIR. The idiom is common in this directory, which makes it
# the shape a new lint would copy from its neighbours; see for yourself with
# `grep -l 'trap .* EXIT' skills/orch/tests/*.sh`. Put scratch under MD_TMP and
# let this trap clean it up.
#
# READING RULES. Every read goes through `_md_scan`, one pass that classifies
# each line as outside a fence, inside one, or a fence delimiter, and blanks
# HTML-comment spans ONLY outside a fence. Three consequences the lints depend
# on. A heading-shaped line inside a fence is not a heading, so the summary
# templates the orch workflows embed (`## Recommendations Processed` at column
# zero, `# Linear` as a shell comment) no longer truncate the section around
# them. A `<!--` inside a fence is literal text, so `printf '<!--'` cannot
# blank every line after it. And a rule commented out inside its own section,
# or by a `<!--` opened above the heading, reads as absent.
#
# A heading argument matches a heading line EXACTLY, after trimming, and a
# heading two lines answer to is reported rather than resolved by document
# position: `## 4. Present And Fix` must not select `## 4. Present And Fix
# Notes` sitting above it.
#
# CONTROL REGIME. `md_report` closes every suite and proves each registered
# rule can go red. What it proves differs by form, and only `rule` and
# `rule_fenced` get the cross-rule check:
#
#   rule, rule_fenced  every occurrence of the rule's first token is deleted
#                      from the line the rule matched, then every rule that
#                      HELD before the mutation is re-evaluated against it.
#                      Exactly the mutated rule must go red. One that reddens
#                      a second rule is redundant with it; one that reddens
#                      nothing has no teeth. Both fail. A rule already red on
#                      the unmutated tree is left out: it reported its own
#                      failure, and counting it here would blame this control.
#   order              A's matched line is moved to just below B's, and the
#                      comparison must reverse. A rule whose regex matches a
#                      second line ahead of B does not reverse, and is
#                      reported as not discriminating.
#   absent             the SAMPLE is inserted directly under the heading and
#                      must be flagged.
#   forbid, forbid_fenced
#                      the SAMPLE is appended to a scratch copy of EVERY
#                      registered file in turn, and each must be flagged.
#   permits            no registry and no control loop: it carries its own
#                      positive half, the PROBE, in line.
#   check              no automatic control. A suite using it owns proving its
#                      teeth.
#
# Three forms can pass on an empty search result — `absent`, `forbid` and
# `permits` — and each now carries a positive control, so none of them can
# report a proof it did not perform. That enumeration is the whole of it: every
# other `pass` here follows a match that was found, or a mutation that was
# verified to have planted something.
#
# The rule control re-evaluates every held rule once per rule, so a suite's
# control pass costs O(N^2) file reads in its rule count. Measure the law
# rather than trusting a number here, which is one machine's on one day:
#
#   for n in 10 20 30 40; do   # N rules, each matching its own fixture line
#     ... build the fixture and the suite, then: time bash the-suite
#   done
#   time (for f in skills/orch/tests/*lint*.test.sh; do bash "$f"; done)
#   grep -cE '^(rule|rule_fenced) ' skills/orch/tests/*lint*.test.sh
#
# The shape that run showed: doubling the rules costs roughly four times the
# time, while every orch lint suite together still finishes in a few seconds,
# well inside the orch shard's timeout — `timeout-minutes` on the
# skill-suites-shard job in `.github/workflows/skill-tests.yml`, which is where
# to read it rather than here. What the law means for an author is that a suite
# growing past roughly thirty rules is paying a superlinear price and is better
# split by contract.
#
# One optimization is applied, above: the held-set pre-check is loop-invariant,
# so computing it once takes the control pass from 2N^2 reads to N^2 + N. The
# commands above are what measure what that is worth on a given machine. What
# was measured and declined is a different set — per-path memoization of the
# reader, a pre-stripped control scratch, and a file-grouped loop, each at 20
# percent or worse against the orch shard's budget, which is what the redesign
# they pointed at was declined against.

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

# _md_indices COUNT — 0..COUNT-1, or nothing. `${!arr[@]}` on an empty array is
# unbound under `set -u` in Bash 3.2, which `SKILL.md` § Configuration declares
# on its System dependencies line, and a suite registering one rule form leaves
# three arrays empty.
_md_indices() {
  local n="$1" i=0
  while [ "$i" -lt "$n" ]; do
    printf '%s\n' "$i"
    i=$((i + 1))
  done
}

# _md_path FILE — the file's canonical absolute path, so two suites spelling
# one physical file two ways still compare equal in `_md_holds`. A path whose
# directory does not exist comes back unchanged; the read that follows reports
# it.
_md_path() {
  local d b
  d="$(dirname -- "$1")"
  b="$(basename -- "$1")"
  if [ -d "$d" ]; then
    printf '%s/%s\n' "$(cd "$d" && pwd -P)" "$b"
  else
    printf '%s\n' "$1"
  fi
}

# _md_scan FILE — one output line per input line, four tab-separated fields:
#
#   STATE  0 outside any fence, 1 inside one, 2 the fence's own ``` delimiter
#   BLOCK  the opening fence's line number, 0 outside a fence
#   LANG   the opening fence's language word, empty when it carries none
#   TEXT   the line, with HTML-comment spans blanked
#
# Fences win over comments and comments win over fences, in that order: a
# ``` line inside an open comment does not open a fence, and a `<!--` inside
# an open fence is literal text. TEXT may hold tabs, so it is always the last
# field and readers take it with a three-field prefix strip.
_md_scan() {
  awk '
    {
      raw = $0
      if (!inc && raw ~ /^[[:space:]]*```/) {
        if (open) {
          printf "2\t%d\t%s\t%s\n", block, lang, raw
          open = 0; block = 0; lang = ""
        } else {
          open = 1; block = NR
          lang = raw
          sub(/^[[:space:]]*```[[:space:]]*/, "", lang)
          sub(/[[:space:]].*$/, "", lang)
          printf "2\t%d\t%s\t%s\n", block, lang, raw
        }
        next
      }
      if (open) { printf "1\t%d\t%s\t%s\n", block, lang, raw; next }
      s = raw; out = ""
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
      printf "0\t0\t\t%s\n", out
    }
  ' "$1"
}

# The three-field prefix every reader strips off a _md_scan row.
MD_STRIP='^[^\t]*\t[^\t]*\t[^\t]*\t'

# _md_text FILE — the file with every HTML-comment span blanked, one output
# line per input line so a reported number is the real one.
_md_text() {
  _md_scan "$1" | awk -F'\t' -v strip="$MD_STRIP" '{ t = $0; sub(strip, "", t); print t }'
}

# _md_head_lines FILE HEADING — the line number of every heading line whose
# trimmed text equals HEADING. An empty HEADING lists every heading.
_md_head_lines() {
  _md_scan "$1" | md_head="$2" awk -F'\t' -v strip="$MD_STRIP" '
    BEGIN { h = ENVIRON["md_head"]; whole = (h == "") }
    {
      text = $0; sub(strip, "", text)
      if ($1 != 0 || text !~ /^[[:space:]]*#+[[:space:]]/) next
      t = text; sub(/^[[:space:]]+/, "", t); sub(/[[:space:]]+$/, "", t)
      if (whole || t == h) print NR
    }
  '
}

# _md_head_line FILE HEADING — the first such line number, or empty.
_md_head_line() { _md_head_lines "$1" "$2" | head -1; }

# _md_head_fault FILE HEADING — a diagnostic when the heading does not name
# exactly one section, else nothing. An empty HEADING always names the file.
_md_head_fault() {
  [ -z "$2" ] && return 0
  local n
  n="$(_md_head_lines "$1" "$2" | grep -c . || true)"
  if [ "$n" -eq 0 ]; then
    printf '%s carries no heading %s\n' "${1##*/}" "$2"
  elif [ "$n" -gt 1 ]; then
    printf '%s carries %s headings reading %s — the selector is ambiguous\n' \
      "${1##*/}" "$n" "$2"
  fi
}

# _md_lines FILE HEADING — "lineno<TAB>text" for the body under the first
# heading line whose trimmed text equals HEADING, ending at the next heading of
# the same or shallower depth. The heading line itself is not part of the body,
# and a heading-shaped line inside a fence is not a heading. An empty HEADING
# reads the whole file, headings excepted.
_md_lines() {
  _md_scan "$1" | md_head="$2" awk -F'\t' -v strip="$MD_STRIP" '
    BEGIN { h = ENVIRON["md_head"]; whole = (h == ""); on = whole }
    done_ { next }
    {
      text = $0; sub(strip, "", text)
      if ($1 == 0 && text ~ /^[[:space:]]*#+[[:space:]]/) {
        if (whole) next
        t = text; sub(/^[[:space:]]+/, "", t); sub(/[[:space:]]+$/, "", t)
        d = 0
        while (substr(t, d + 1, 1) == "#") d++
        if (!on) { if (t == h) { on = 1; depth = d } ; next }
        if (d <= depth) { on = 0; done_ = 1; next }
      }
      if (on) printf "%d\t%s\n", NR, text
    }
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
  _md_scan "$1" | awk -F'\t' -v strip="$MD_STRIP" '
    $1 == 1 && ($3 == "bash" || $3 == "sh") {
      text = $0; sub(strip, "", text)
      t = text; sub(/^[[:space:]]+/, "", t)
      if (t == "" || substr(t, 1, 1) == "#") next
      printf "%d\t%d\t%s\n", $2, NR, text
    }
  '
}

# _md_body MODE FILE HEADING — "lineno<TAB>text" a rule may match against.
# MODE `line` is every body line; MODE `fenced` is the body lines that are also
# fenced command lines, so a rule pinning an executable invocation cannot be
# satisfied by a prose mention or a ```json block.
_md_body() {
  if [ "$1" = fenced ]; then
    local keep
    keep="$(fenced "$2" | cut -f2)"
    _md_lines "$2" "$3" | awk -F'\t' -v k="$keep" '
      BEGIN { n = split(k, a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") keep[a[i]] = 1 }
      ($1 in keep) { print }
    '
  else
    _md_lines "$2" "$3"
  fi
}

# _md_match MODE FILE HEADING TOKEN... — the line number of the first body line
# holding every TOKEN, or empty.
_md_match() {
  local mode="$1" file="$2" heading="$3"
  shift 3
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
  done < <(_md_body "$mode" "$file" "$heading")
  return 1
}

# _md_fields REC — splits a registry record into the MD_F array.
_md_fields() {
  local old="$IFS"
  IFS="$MD_SEP"
  read -r -a MD_F <<<"$1"
  IFS="$old"
}

# _md_rule MODE NAME FILE HEADING TOKEN...
_md_rule() {
  local mode="$1" name="$2" file heading="$4"
  file="$(_md_path "$3")"
  shift 4
  local rec="$name$MD_SEP$mode$MD_SEP$file$MD_SEP$heading" t
  for t in "$@"; do rec="$rec$MD_SEP$t"; done
  MD_RULES+=("$rec")
  local fault
  fault="$(_md_head_fault "$file" "$heading")"
  if [ -n "$fault" ]; then
    fail "$name — $fault"
  elif [ -n "$(_md_match "$mode" "$file" "$heading" "$@")" ]; then
    pass "$name"
  elif [ "$mode" = fenced ]; then
    fail "$name — no fenced command under '$heading' in ${file##*/} holds: $*"
  else
    fail "$name — no line under '$heading' in ${file##*/} holds: $*"
  fi
}

# rule NAME FILE HEADING TOKEN...
rule() { _md_rule line "$@"; }

# rule_fenced NAME FILE HEADING TOKEN... — the match must be a command line
# inside a ```bash/```sh fence. Use it wherever the contract is that a workflow
# RUNS something; `rule` stays for headings, table rows, schema fields and
# state keys, which are prose-level facts.
rule_fenced() { _md_rule fenced "$@"; }

# _md_holds REC ORIG SCRATCH — re-evaluates one rule, reading SCRATCH in place
# of ORIG. Both paths are canonical, so the substitution does not depend on how
# a suite spelled the file.
_md_holds() {
  _md_fields "$1"
  local f="${MD_F[2]}"
  [ "$f" = "$2" ] && f="$3"
  [ -n "$(_md_match "${MD_F[1]}" "$f" "${MD_F[3]}" "${MD_F[@]:4}")" ]
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

# order NAME FILE RE_A RE_B — A's first match precedes B's.
order() {
  MD_ORDERS+=("$1$MD_SEP$(_md_path "$2")$MD_SEP$3$MD_SEP$4")
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

# absent NAME FILE HEADING RE SAMPLE — no line under HEADING matches RE.
# absent_i is the same, case-insensitively, for a shape whose capitalization is
# the author's rather than the contract's: a reintroduced `apply fixes?` menu
# is the menu whatever case it is written in. A heading that names no section,
# or two, is a failure rather than an empty read: an absence check over nothing
# passes for the wrong reason.
_md_absent() {
  local fold="$1"
  shift
  MD_ABSENTS+=("$1$MD_SEP$(_md_path "$2")$MD_SEP$3$MD_SEP$4$MD_SEP$5$MD_SEP$fold")
  local fault body hit
  fault="$(_md_head_fault "$2" "$3")"
  if [ -n "$fault" ]; then
    fail "$1 — $fault"
    return
  fi
  body="$(section "$2" "$3")"
  if [ -z "$body" ]; then
    fail "$1 — '$3' in ${2##*/} has an empty body, so there is nothing to check"
    return
  fi
  hit="$(grep -nE $fold -e "$4" <<<"$body" || true)"
  if [ -z "$hit" ]; then
    pass "$1"
  else
    fail "$1"
    printf '%s\n' "$hit" | sed 's/^/          /'
  fi
}
absent() { _md_absent "" "$@"; }
absent_i() { _md_absent -i "$@"; }

# _md_scannable F — true when F is a regular file this process can read. A
# directory passes `-r`, and awk then warns and skips it while grep's no-match
# 1 is the rightmost status `pipefail` reports, so an unreadable target would
# read as a clean one. This is guard code: what nobody read is not clean.
_md_scannable() { [ -f "$1" ] && [ -r "$1" ]; }

# _md_offenders RE FILE... — "file:line: text" per matching line. A target that
# is not a readable regular file, or that a scan fails on, is itself an
# offender.
_md_offenders() {
  local re="$1" f out rc
  shift
  for f in "$@"; do
    if ! _md_scannable "$f"; then
      printf '%s: not a readable file\n' "${f#$REPO_ROOT/}"
      continue
    fi
    out="$(_md_text "$f" | grep -nE -e "$re")" && rc=0 || rc=$?
    if [ "$rc" -gt 1 ]; then
      printf '%s: scan failed with exit %s\n' "${f#$REPO_ROOT/}" "$rc"
      continue
    fi
    [ -n "$out" ] && printf '%s\n' "$out" | sed "s|^|${f#$REPO_ROOT/}:|"
  done
  return 0
}

# _md_fenced_hits RE FILE... — the same, over fenced command lines. RE is
# matched against the command text alone; the line number is reported.
_md_fenced_hits() {
  local re="$1" f out rc
  shift
  for f in "$@"; do
    if ! _md_scannable "$f"; then
      printf '%s: not a readable file\n' "${f#$REPO_ROOT/}"
      continue
    fi
    out="$(fenced "$f" | md_re="$re" awk -F'\t' -v p="${f#$REPO_ROOT/}" '
      BEGIN { re = ENVIRON["md_re"] }
      { t = $0; sub(/^[0-9]+\t[0-9]+\t/, "", t); if (t ~ re) printf "%s:%s: %s\n", p, $2, t }
    ')" && rc=0 || rc=$?
    if [ "$rc" -ne 0 ]; then
      printf '%s: scan failed with exit %s\n' "${f#$REPO_ROOT/}" "$rc"
      continue
    fi
    [ -n "$out" ] && printf '%s\n' "$out"
  done
  return 0
}

# _md_forbid MODE NAME RE SAMPLE FILE... — no line in any FILE matches RE.
# SAMPLE is a line that must match, appended to a scratch copy of every
# registered file by the control.
_md_forbid() {
  local mode="$1" name="$2" re="$3" sample="$4"
  shift 4
  # An absence check over no files passes for the wrong reason, exactly as one
  # over an empty section does. A suite building its list conditionally is the
  # reachable shape; an unexpanded glob is caught below as an unreadable path.
  if [ "$#" -eq 0 ]; then
    fail "$name — no scan target was registered, so there is nothing to check"
    return
  fi
  local rec="$name$MD_SEP$re$MD_SEP$sample$MD_SEP$mode" f
  for f in "$@"; do rec="$rec$MD_SEP$f"; done
  MD_FORBIDS+=("$rec")
  local out
  if [ "$mode" = fenced ]; then
    out="$(_md_fenced_hits "$re" "$@")"
  else
    out="$(_md_offenders "$re" "$@")"
  fi
  if [ -z "$out" ]; then
    pass "$name"
  else
    fail "$name"
    printf '%s\n' "$out" | sed 's/^/          /'
  fi
}

forbid() { _md_forbid line "$@"; }
forbid_fenced() { _md_forbid fenced "$@"; }

# permits NAME RE PROBE SAMPLE FILE — the near-miss half of a `forbid`: SAMPLE
# appended to FILE must NOT be flagged.
#
# PROBE is the positive half, and it is what makes the pass mean something.
# `permits` is the third of the three forms that pass on an empty search
# result, and the only one with no control loop behind it, so nothing else
# would notice that the scan never reached the appended line at all. Two real
# shapes do exactly that: a base whose last line opens an HTML comment that
# never closes blanks whatever is appended after it, and a base with an odd
# number of fences turns the fenced append's opening ``` into the closer of the
# fence already open. PROBE goes down the same append path, in the same mode,
# and must be flagged — so "the scanner read my appended line" is a
# precondition of the near-miss verdict rather than an assumption.
_md_permits() {
  local name="$1" re="$2" probe="$3" sample="$4" file="$5" mode="$6"
  if ! _md_scannable "$file"; then
    fail "$name — ${file#$REPO_ROOT/} is not a readable file"
    return
  fi
  local hit
  hit="$(_md_permit_hits "$re" "$file" "$probe" "$mode")"
  if [ -z "$hit" ]; then
    fail "$name — the probe line was not flagged, so the scan never reached what it appended"
    return
  fi
  hit="$(_md_permit_hits "$re" "$file" "$sample" "$mode")"
  if [ -z "$hit" ]; then pass "$name"; else fail "$name — flagged: $hit"; fi
}

# _md_permit_hits RE FILE LINE MODE — offenders after appending LINE to a
# scratch copy of FILE, through the mode's own append path.
_md_permit_hits() {
  MD_PERMITS=$((MD_PERMITS + 1))
  local scratch="$MD_TMP/permit-$MD_PERMITS.md"
  cp "$2" "$scratch"
  if [ "$4" = fenced ]; then
    printf '\n```bash\n%s\n```\n' "$3" >>"$scratch"
    _md_fenced_hits "$1" "$scratch"
  else
    printf '\n%s\n' "$3" >>"$scratch"
    _md_offenders "$1" "$scratch"
  fi
}
permits() { _md_permits "$1" "$2" "$3" "$4" "$5" line; }
permits_fenced() { _md_permits "$1" "$2" "$3" "$4" "$5" fenced; }

# check NAME CMD... — a bespoke predicate, for a contract the rule forms above
# cannot express: a count across a directory, a containment, a rendered
# template. It carries no automatic control, so a suite using it owns proving
# its teeth.
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
  local i j k rec scratch ln reddened victim
  # Which rules hold on the UNMUTATED tree. A rule already red reported its own
  # failure above, and counting it inside a control would blame that control
  # for it. The answer does not depend on which rule is being mutated, so it is
  # computed once here rather than N times inside the inner loop: it is the
  # difference between N^2 + N reads and 2N^2. Bash 3.2 has no associative
  # array, so membership is a space-delimited index string.
  local held=" "
  for k in $(_md_indices "${#MD_RULES[@]}"); do
    if _md_holds "${MD_RULES[$k]}" "" ""; then held="$held$k "; fi
  done
  for i in $(_md_indices "${#MD_RULES[@]}"); do
    rec="${MD_RULES[$i]}"
    _md_fields "$rec"
    local name="${MD_F[0]}" mode="${MD_F[1]}" file="${MD_F[2]}"
    # `|| true` or the first rule matching nothing aborts this function under
    # `set -e`, which is what the guard below exists to prevent: a maintainer
    # fixing one broken rule would learn nothing about the rest of the suite.
    ln="$(_md_match "$mode" "$file" "${MD_F[3]}" "${MD_F[@]:4}" || true)"
    # No match: the rule itself already reported FAIL above, and a control over
    # a line that is not there would only repeat it.
    if [ -z "$ln" ]; then continue; fi
    scratch="$MD_TMP/rule-$i.md"
    _md_strike "$file" "$ln" "${MD_F[4]}" "$scratch"
    if cmp -s "$file" "$scratch"; then
      fail "control for '$name' planted nothing — '${MD_F[4]}' is not on line $ln"
      continue
    fi
    reddened=""
    for j in $(_md_indices "${#MD_RULES[@]}"); do
      case "$held" in *" $j "*) ;; *) continue ;; esac
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

  # An order control MOVES A's line to just below B's rather than swapping the
  # two, so it can fail: a regex matching a second line ahead of B does not
  # reverse, and the rule is not pinning what it names.
  for i in $(_md_indices "${#MD_ORDERS[@]}"); do
    _md_fields "${MD_ORDERS[$i]}"
    local oname="${MD_F[0]}" ofile="${MD_F[1]}" ore_a="${MD_F[2]}" ore_b="${MD_F[3]}"
    local a b ca cb
    a="$(_md_first "$ofile" "$ore_a")"
    b="$(_md_first "$ofile" "$ore_b")"
    if [ -z "$a" ] || [ -z "$b" ]; then continue; fi
    scratch="$MD_TMP/order-$i.md"
    awk -v x="$a" -v y="$b" '
      { l[NR] = $0 }
      END {
        for (k = 1; k <= NR; k++) {
          if (k == x) continue
          print l[k]
          if (k == y) print l[x]
        }
      }
    ' "$ofile" >"$scratch"
    ca="$(_md_first "$scratch" "$ore_a")"
    cb="$(_md_first "$scratch" "$ore_b")"
    if [ -n "$ca" ] && [ -n "$cb" ] && [ "$cb" -lt "$ca" ]; then
      pass "control: '$oname' goes red when /$ore_a/ moves below /$ore_b/"
    else
      fail "control for '$oname' — moving /$ore_a/ below /$ore_b/ did not reverse the order; the regex matches a second line ahead of it"
    fi
  done

  for i in $(_md_indices "${#MD_ABSENTS[@]}"); do
    _md_fields "${MD_ABSENTS[$i]}"
    local aname="${MD_F[0]}" afile="${MD_F[1]}" ahead="${MD_F[2]}" are="${MD_F[3]}"
    local asample="${MD_F[4]}" afold="${MD_F[5]:-}" hl
    hl="$(_md_head_line "$afile" "$ahead")"
    scratch="$MD_TMP/absent-$i.md"
    if [ -z "$hl" ]; then
      fail "control for '$aname' — ${afile##*/} carries no heading '$ahead'"
      continue
    fi
    awk -v ln="$hl" -v s="$asample" 'NR == ln { print; print ""; print s; next } { print }' \
      "$afile" >"$scratch"
    if [ -n "$(section "$scratch" "$ahead" | grep -E $afold -e "$are" || true)" ]; then
      pass "control: '$aname' flags its sample"
    else
      fail "control for '$aname' — the sample under '$ahead' is not flagged"
    fi
  done

  # Every registered file, not the first: a forbid spanning a glob otherwise
  # proves its regex on one file and never proves the rest are readable.
  for i in $(_md_indices "${#MD_FORBIDS[@]}"); do
    _md_fields "${MD_FORBIDS[$i]}"
    local fname="${MD_F[0]}" fre="${MD_F[1]}" fsample="${MD_F[2]}" mode="${MD_F[3]}"
    local base missed=0 checked=0 k
    for k in $(_md_indices "${#MD_F[@]}"); do
      [ "$k" -lt 4 ] && continue
      base="${MD_F[$k]}"
      scratch="$MD_TMP/forbid-$i-$k.md"
      # Tested before `cp`, which on a directory dies under `set -e` and takes
      # the tally with it, leaving a cp error where the verdict should be.
      if ! _md_scannable "$base"; then
        fail "control for '$fname' — ${base#$REPO_ROOT/} is not a readable file"
        missed=$((missed + 1))
        continue
      fi
      cp "$base" "$scratch"
      checked=$((checked + 1))
      if [ "$mode" = fenced ]; then
        printf '\n```bash\n%s\n```\n' "$fsample" >>"$scratch"
        [ -n "$(_md_fenced_hits "$fre" "$scratch")" ] && continue
      else
        printf '\n%s\n' "$fsample" >>"$scratch"
        [ -n "$(_md_offenders "$fre" "$scratch")" ] && continue
      fi
      fail "control for '$fname' — the sample is not flagged in ${base#$REPO_ROOT/}"
      missed=$((missed + 1))
    done
    if [ "$checked" -eq 0 ]; then
      fail "control for '$fname' — no registered file could be read, so it proved nothing"
    elif [ "$missed" -eq 0 ]; then
      pass "control: '$fname' flags its sample in every file it read ($checked)"
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
