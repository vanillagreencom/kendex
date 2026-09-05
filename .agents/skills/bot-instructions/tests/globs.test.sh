#!/usr/bin/env bash
# The glob dialect's vectors.
#
# The dialect claims a set of patterns five targets read alike. That is a claim
# about five engines rather than about this code, and only one of the five can
# be asked from a repo with no third-party runtime: **git's own wildmatch**,
# which is the engine `git sparse-checkout` uses and which CodeRabbit feeds
# `path_filters` to. minimatch needs a Node runtime this package does not
# depend on; Copilot's `applyTo` matcher, Qodo's `[ignore]` matcher and
# Macroscope's `include` matcher are unpublished. Those four are a one-time
# confirmation in `references/checklist.md`, and claiming conformance from a
# harness that cannot reach them would be the false confidence the validators
# exist to prevent.
#
# What this measures is therefore this package's own matcher — the one the
# dead-exclusion clause decides with — against git's. A disagreement there
# means a dead-exclusion verdict is wrong.
#
# THE HARNESS NEEDS ITS OWN CONTROL, and it cannot be a pattern the dialect
# allows: if the dialect is right, no such pattern produces disagreement, so
# that control could only be built by first finding a dialect bug. The
# buildable one runs the other way — feed a pattern the dialect REFUSES with
# the dialect check bypassed, and assert the harness reports the disagreement.

. "$(dirname "$0")/lib/harness.sh"

work="$BI_TMP/globs"
mkdir -p "$work/a/b" "$work/ab" "$work/docs"
git -C "$work" init -q .
# `solo` is a tracked FILE with no tree under it, which is what makes
# `solo/**` a boundary case rather than a repetition of `a/**`: git selects
# nothing for it, and a translation that lets a trailing `/**` match the
# directory itself selects the file.
#
# `docs` and `doc?` are the pair on git's other rule: a pathspec holding no
# wildcard covers the paths beneath it, and one holding any of `*?[` does not.
# `docs` selects `docs/x.md` and `doc?` selects nothing, so a matcher missing
# the rule disagrees on the first and one applying it to every pattern
# disagrees on the second.
for f in a/f a/b/g ab/h top.md docs/x.md solo; do printf 'x\n' > "$work/$f"; done
git -C "$work" add -A >/dev/null 2>&1

# One vector: git's selection for the pattern against this package's.
vector() {
  local pattern want_agree theirs mine
  pattern="$1"
  want_agree="$2"
  local refused=0
  theirs="$(git -C "$work" ls-files -- ":(glob)$pattern" 2>/dev/null | LC_ALL=C sort | tr '\n' ' ' | sed 's/  *$//')" || refused=1
  git -C "$work" ls-files -- ":(glob)$pattern" >/dev/null 2>&1 || refused=1
  mine="$(python3 - "$work" "$pattern" <<'PY'
import subprocess, sys, os
sys.path.insert(0, os.path.join(os.environ["BI_ROOT"], "skills/bot-instructions/scripts"))
from lib import globs
work, pattern = sys.argv[1], sys.argv[2]
tracked = subprocess.run(["git", "-C", work, "ls-files", "-z"], capture_output=True)
paths = [p for p in tracked.stdout.decode().split("\0") if p]
print(" ".join(sorted(globs.matching(pattern, paths))))
PY
)"
  mine="$(printf '%s' "$mine" | sed 's/  *$//')"
  case "$want_agree" in
    agree)
      if [ "$refused" -eq 0 ] && [ "$theirs" = "$mine" ]; then
        ok "agrees with git's wildmatch: $pattern"
      else
        bad "agrees with git's wildmatch: $pattern" "git [$theirs] refused=$refused vs this package [$mine]"
      fi ;;
    disagree)
      if [ "$theirs" != "$mine" ]; then ok "the harness reports a disagreement: $pattern"
      else bad "the harness reports a disagreement: $pattern" "both selected [$theirs]"; fi ;;
    refused)
      if [ "$refused" -eq 1 ]; then
        ok "git refuses the pathspec rather than answering: $pattern"
      else
        bad "git refuses the pathspec rather than answering: $pattern" "git answered [$theirs]"
      fi ;;
  esac
}

export BI_ROOT

# Every shape the dialect permits.
for p in 'a/**' 'a/*' '**' '*' '*.md' '**/*.md' '**/g' 'a/**/g' 'a/*/g' 'a/b/**' \
         'a?f' 'a**' '[a]b/h' 'docs/**' 'top.md' 'solo/**' 'docs' 'doc?'; do
  vector "$p" agree
done

# The harness's own control, on inputs the dialect refuses. An empty component
# is the sharpest: git normalizes `a//f` to `a/f` and selects a file, and this
# package's matcher selects nothing — one pattern, two answers, which is
# exactly why the path-shape rule refuses it rather than letting it render.
vector 'a//f' disagree

# A leading `/` and a `..` component disagree differently: git refuses the
# pathspec outright rather than answering, so a rendered exclusion carrying one
# is not a narrow exclusion but a broken checkout.
vector '/a/f' refused
vector '../a/f' refused

# The refusals are stated as a character class rather than as a list of banned
# sequences, and this is the difference: a ban list closes the shapes someone
# thought of, and every byte below is outside the class whether or not anyone
# named it.
for bad_pattern in '{a,ab}/**' '@(a|ab)/**' 'a,b' 'a#b' 'a!b' 'a"b'; do
  if python3 -c "
import sys, os
sys.path.insert(0, os.path.join(os.environ['BI_ROOT'], 'skills/bot-instructions/scripts'))
from lib import globs
from lib.errors import InputError
try:
    globs.check(sys.argv[1], 'vector')
except InputError:
    raise SystemExit(0)
raise SystemExit(1)
" "$bad_pattern"; then
    ok "the dialect refuses: $bad_pattern"
  else
    bad "the dialect refuses: $bad_pattern"
  fi
done

# `**/` translates to `(?:[^/]*/)*`, and nesting those is exponential in the
# number of `**`: rejecting a deep path took seconds at a dozen, inside the
# clause that runs this once per tracked path. Consecutive runs collapse to
# one, which is a rewrite of the pattern and not of its meaning, so this is
# two assertions — the results are unchanged, and the cost is bounded.
if python3 - "$BI_ROOT/skills/bot-instructions" <<'PROBE'; then
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "scripts"))
from lib import globs

paths = ["a", "a/b", "a/x/b", "b", "a/x/y/b", "a/b/c", "x/b", "a/x/y/z/b"]
for n in range(1, 6):
    many = "a/" + "**/" * n + "b"
    for p in paths:
        if bool(globs.matching(many, [p])) != bool(globs.matching("a/**/b", [p])):
            sys.exit(f"{many!r} and 'a/**/b' disagree on {p!r}")
# In a child with a hard deadline: uncollapsed, twenty `**` against a
# twenty-deep path does not return in any time a CI lane will wait, and a
# control that waits with it reports a timeout rather than a failure.
import subprocess
probe = (
    "import sys; sys.path.insert(0, %r);"
    "from lib import globs;"
    "globs.matching('a/' + '**/' * 20 + 'b',"
    " ['a/' + '/'.join('d%%d' %% i for i in range(20)) + '/x'])"
    % os.path.join(sys.argv[1], "scripts")
)
try:
    subprocess.run([sys.executable, "-c", probe], timeout=10, check=True,
                   capture_output=True)
except subprocess.TimeoutExpired:
    sys.exit("twenty `**` against a twenty-deep path did not finish in 10s")
except subprocess.CalledProcessError as exc:
    sys.exit(f"the match raised: {exc.stderr.decode()[:200]}")
PROBE
  ok 'consecutive `**` collapse: same matches, bounded cost'
else
  bad 'consecutive `**` collapse: same matches, bounded cost'
fi

bi_summary
