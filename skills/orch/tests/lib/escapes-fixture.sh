# shellcheck shell=bash
#
# The neutral world the escape count (scripts/lib/escapes.sh) reads, shared by
# oversee_report_escapes.sh and oversee_report.sh: a checkout whose origin is
# a bare repository beside it, a commit on main at a chosen time, and a bug
# issue in the Linear cache's shape. Nothing here plants a defect; each suite
# writes its own merges, reverts and bug issues, and its own Linear CLI stub.
#
# Sourced, never run: the runners glob tests/*.sh, so the `lib/` prefix keeps
# this file out of the run. The sourcing suite has sourced git-env.sh.

# escapes_checkout DIR — DIR a git checkout on main whose origin is the bare
# repository DIR.origin, with git's background maintenance off.
escapes_checkout() {
  local dir="$1"
  git init -q --bare "$dir.origin" || return 1
  git -C "$dir.origin" symbolic-ref HEAD refs/heads/main || return 1
  git init -q "$dir" || return 1
  git -C "$dir" config gc.auto 0 || return 1
  git -C "$dir" config maintenance.auto false || return 1
  git -C "$dir" checkout -q -b main || return 1
  git -C "$dir" remote add origin "$dir.origin"
}

# escapes_commit DIR EPOCH SUBJECT — one empty commit on DIR's main, authored
# and committed at EPOCH in UTC.
escapes_commit() {
  GIT_AUTHOR_DATE="$2 +0000" GIT_COMMITTER_DATE="$2 +0000" \
    git -C "$1" -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false \
    commit -q --allow-empty -m "$3"
}

# escapes_publish DIR — DIR's main pushed to its origin, where the count's
# fetch reads it.
escapes_publish() {
  git -C "$1" push -q origin main
}

# escapes_bug ID EPOCH TEXT — one bug issue in the Linear cache's safe shape,
# created at EPOCH, TEXT its title; the suite's Linear CLI stub answers the
# bug list with a JSON array of these.
escapes_bug() {
  jq -cn --arg id "$1" --arg at "$(jq -rn --argjson t "$2" '$t | todate | sub("Z$"; ".000Z")')" --arg text "$3" \
    '{id: $id, title: $text, description: "Symptom: see the title.", created_at: $at, labels: ["bug"]}'
}

