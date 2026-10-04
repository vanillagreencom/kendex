# shellcheck shell=bash
# The overseer's checkout as a launch finds it, for the suites whose launches
# fast-forward it (scripts/lib/overseer-launch.sh § ol_checkout_sync). Sourced
# after TMP_ROOT is made; requires git.
#
#   checkout_world DIR   DIR, an existing directory, made a checkout of main
#                        tracking the bare origin $TMP_ROOT/origin.git at its
#                        head, its own files left untracked. Also lays the
#                        github skill's git wrapper and its libs beside every
#                        mutant_scripts copy (growth-state.sh), where
#                        sync-base reads them from, so a mutant launch syncs
#                        as a real one.
#   checkout_advance     one more commit on origin's main, its sha printed:
#                        origin's main one commit further ahead.
#   checkout_commit DIR  one local commit on DIR's branch, its sha printed.

checkout_git() { git -c user.name=fixture -c user.email=fixture@example.com -c commit.gpgsign=false "$@"; }
# Git's background maintenance is off in each repository the suite's exit
# removes, so the removal cannot race its writer.
checkout_quiet() { # REPO
  git -C "$1" config gc.auto 0 && git -C "$1" config maintenance.auto false
}

checkout_world() { # DIR
  local origin="$TMP_ROOT/origin.git" seed="$TMP_ROOT/origin-seed" lib
  lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
  # shellcheck source=shared-skill-libs.sh
  source "$lib/shared-skill-libs.sh" || return 1
  orch_fixture_shared_libs "$TMP_ROOT/checkout" || return 1
  cp -p -- "$lib/../../../github/scripts/git-https-auth" "$TMP_ROOT/github/scripts/" || return 1
  if [[ ! -d "$origin" ]]; then
    git init -q --bare -b main "$origin" && checkout_quiet "$origin" || return 1
    git init -q -b main "$seed" && checkout_quiet "$seed" || return 1
    printf 'seed\n' > "$seed/README" || return 1
    checkout_git -C "$seed" add README || return 1
    checkout_git -C "$seed" commit -q -m seed || return 1
    git -C "$seed" push -q "$origin" main || return 1
  fi
  git -C "$1" init -q -b main && checkout_quiet "$1" || return 1
  git -C "$1" remote add origin "$origin" || return 1
  git -C "$1" fetch -q origin || return 1
  git -C "$1" reset -q origin/main || return 1
  git -C "$1" checkout -q -- . || return 1
  git -C "$1" branch -q --set-upstream-to=origin/main main || return 1
  git -C "$1" remote set-head origin main || return 1
}

checkout_advance() {
  local seed="$TMP_ROOT/origin-seed"
  printf 'advance %s\n' "$(date +%s%N)" >> "$seed/README" || return 1
  checkout_git -C "$seed" commit -q -am advance || return 1
  git -C "$seed" push -q "$TMP_ROOT/origin.git" main || return 1
  git -C "$seed" rev-parse HEAD
}

checkout_commit() { # DIR
  checkout_git -C "$1" commit -q --allow-empty -m local || return 1
  git -C "$1" rev-parse HEAD
}
