# shellcheck shell=bash
#
# The neutral world the escape count (scripts/lib/escapes.sh) reads, shared by
# oversee_report_escapes.sh and oversee_report.sh: a checkout whose origin is
# a bare repository beside it, a commit or a merge on main at a chosen time,
# and an issue in the Linear cache's shape. Nothing here plants a defect; each
# suite writes its own merges, reverts and issues, and its own Linear CLI stub.
#
# Sourced, never run: the runners glob tests/*.sh, so the `lib/` prefix keeps
# this file out of the run. The sourcing suite has sourced git-env.sh.

# escapes_checkout DIR — DIR a git checkout on main whose origin is the bare
# repository DIR.origin, with git's background maintenance off in both.
escapes_checkout() {
  local dir="$1"
  git init -q --bare "$dir.origin" || return 1
  git -C "$dir.origin" config gc.auto 0 || return 1
  git -C "$dir.origin" config maintenance.auto false || return 1
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

# escapes_merge DIR EPOCH SUBJECT SIDE_SUBJECT — a merge commit SUBJECT on
# DIR's main at EPOCH, its second parent a branch commit SIDE_SUBJECT made an
# hour earlier, the shape of GitHub's `Merge pull request #N` merge.
escapes_merge() {
  git -C "$1" checkout -q -b side || return 1
  escapes_commit "$1" "$(($2 - 3600))" "$4" || return 1
  git -C "$1" checkout -q main || return 1
  GIT_AUTHOR_DATE="$2 +0000" GIT_COMMITTER_DATE="$2 +0000" \
    git -C "$1" -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false \
    merge -q --no-ff -m "$3" side || return 1
  git -C "$1" branch -q -D side
}

# escapes_publish DIR — DIR's main pushed to its origin, where the count's
# fetch reads it.
escapes_publish() {
  git -C "$1" push -q origin main
}

# escapes_bug ID EPOCH TITLE [DESCRIPTION] [LABEL] — one issue in the Linear
# cache's safe shape, created at EPOCH, labelled LABEL, `bug` by default; the
# suite's Linear CLI stub answers the issue list with a JSON array of these.
escapes_bug() {
  jq -cn --arg id "$1" --arg at "$(jq -rn --argjson t "$2" '$t | todate | sub("Z$"; ".000Z")')" --arg title "$3" \
    --arg description "${4:-Symptom: see the title.}" --arg label "${5:-bug}" \
    '{id: $id, title: $title, description: $description, created_at: $at, labels: [$label]}'
}

