#!/bin/bash
# Help text lives in these functions, printed through quoted heredocs so no
# variable, command substitution, or backtick in the text ever expands — help
# is inert documentation, never code.
print_worktree_usage() {
  worktree_message help commands
  cat <<'EOF'
Usage: worktree <command> [ID|/path] [options]

Portable git worktree manager. Worktrees live outside the repo root at
<parent-of-checkout>/.worktrees/<checkout-name>/<id>; WORKTREE_BASE_DIR
overrides the parent directory.

Commands:
  create ID        Claim a new issue worktree. Refuses implicit reuse when a
                   worktree, branch, or PR already exists (create --help)
  restack ACTION   Guardedly continue, skip, or abort a tool-created paused
                   restack (restack --help)
  list             List all worktrees
  remove ID|PATH   Remove a worktree, clean symlinks, prune its branch
                   (remove --help)
  cleanup          Remove worktrees whose branches are merged (cleanup --help)
  path ID          Print the worktree path for an issue ID
  exists ID        Check whether a worktree exists for an issue ID
  check            Pre-create git state check of the MAIN checkout (JSON:
                   uncommitted, unpushed); takes no arguments
  push [ID|PATH]   Push the worktree branch with auto-rebase (push --help)
  fix-links        Restore configured symlinks in a worktree (fix-links --help)
  repair-links     Git-hook-driven variant of fix-links that never destroys
                   untracked data (fix-links --help)
  codex-setup | codex-branch | codex-cleanup
                   Codex Desktop app-created worktree hooks
  claude-setup | claude-cleanup
                   Claude Code worktree hooks (WorktreeCreate)

Each mutating command's full contract is its own --help.

Path arguments and canonicalization:
  The project root resolves via git rev-parse (at any depth, inside worktrees
  too). Issue IDs that derive paths must match [A-Za-z0-9][A-Za-z0-9._-]* and
  must not contain '..'. Issue-ID resolution prefers the configured base dir
  and falls back to the worktree registered for the issue branch; there is no
  auto-migration. Path comparisons are canonical (physical, symlink-resolved
  on both sides). Direct path arguments for mutating commands must be
  registered worktrees of this repository's common Git directory: fix-links,
  codex-setup, codex-branch, claude-setup, and remove refuse the main checkout
  and foreign worktrees. Codex app-created worktrees are registered git
  worktrees and are accepted even outside WORKTREE_BASE_DIR.

Configuration (loaded lowest to highest: kendex.settings.toml [env], then
.kendex/settings.toml [env], then .env.local — later wins, and explicit
parent environment beats every project file; use .env.local for secrets or
personal overrides):
  WORKTREE_BASE_DIR           Parent directory for created worktrees. Relative
                              paths resolve from the main checkout; absolute
                              paths and ~ are used as-is. Default:
                              ../.worktrees/<checkout-name>, an external
                              per-repo sibling dir. Do not point it inside the
                              repo root.
  WORKTREE_DEFAULT_BRANCH     Default branch name (auto-detected if unset;
                              fallback: main)
  WORKTREE_SYMLINKS           Space-separated paths symlinked from the main
                              checkout into each worktree. Point entries at
                              untracked runtime paths (an entry that shadows
                              tracked files is linked per child instead — see
                              fix-links --help). Include .env.local only if
                              worktrees should share local secrets/overrides.
  WORKTREE_RELATIVE_SYMLINKS  Space-separated path=target symlinks created
                              inside each worktree; relative targets resolve
                              from the link location.
  WORKTREE_COPIES             Space-separated files copied from the main
                              checkout into each worktree.
  WORKTREE_MKDIRS             Space-separated directories created inside each
                              worktree with mkdir -p (gitignored scratch dirs
                              such as tmp).
  BOT_NAME / BOT_EMAIL        git identity for worktree commits
  BOT_SIGNING_KEY             SSH signing key path
  BOT_REMOTE_NAME             Remote name for push (default: origin)
  BOT_REMOTE_URL              URL for the bot remote (added on create if set)

Setup-path hardening:
  Configured setup paths (WORKTREE_SYMLINKS, WORKTREE_COPIES, WORKTREE_MKDIRS,
  and the path side of WORKTREE_RELATIVE_SYMLINKS) must be worktree-relative
  literal paths without '.', '..', absolute, backslash, or shell glob
  metacharacter components (*, ?, [, ]). A configured symlink path cannot also
  be, contain, or parent another configured setup path. Existing symlink
  parents are rejected before writes. Copy and mkdir destinations also reject
  leaf symlinks. File and relative-symlink destinations may replace an
  existing leaf symlink or file without following it, but refuse a real
  directory leaf.

Dependencies:
  No command runs a package-manager install: installs run only in the main
  checkout, and only when the lockfile changed. Link it into each worktree
  with a WORKTREE_SYMLINKS entry for the node_modules path. A configured
  node_modules entry beside a worktree package.json always warns when its
  source is missing; a root package.json with nothing linked warns wherever
  links are set up, but not from repair-links. Limitation: linked node_modules
  resolves pnpm workspace dependencies (workspace:/link:) to main's source, so
  a worktree's checks see main's copy of sibling packages.

Session guard:
  create never claims an ownership lease — a fresh worktree is unclaimed, and
  claiming is the calling workflow's job. The lease is a native git worktree
  lock managed by worktree-session-guard (see its --help for the probe,
  release, sweep, and exit-code contract).
EOF
}

print_restack_help() {
  worktree_message help restack
  cat <<'EOF'
Usage: worktree restack continue|skip|abort [ID|/path]

Control a tool-created paused restack (started by create --restack, with or
without --replay).

Actions:
  continue   Continue an exact tool-created, paused restack; repeat if it
             stops again on the next conflict
  skip       Skip the current commit in that paused restack (use when the
             commit is already represented by the new base)
  abort      Abort that paused restack, restore the recorded original head,
             and clear the pending authorization; with the paused restack
             already gone, clear the record it left behind

Guarded-restack contract: while a restack is paused, the actions accept only a
registered worktree whose worktree-local restack authorization, tool-created
state token, and Git sequencer metadata agree on the exact remote, branch,
observed remote OID, original head, and target base. continue and skip re-check
the remote before and after replay, finalize the exact rewritten-head lease when
complete, and fail closed on missing, stale, or unrelated state. abort requires
that same state except HEAD's own position, which it restores, and remote
movement does not block it. With no restack paused there is no sequencer state
to agree with, so abort takes the record alone: it requires the recorded branch
to still be at its recorded original head, checks that branch out, clears the
record, and re-applies worktree setup, refusing and keeping the record when the
branch has moved or the checkout fails.
EOF
}

print_create_help() {
  worktree_message help create
  cat <<'EOF'
Usage: worktree create <ID> [BRANCH] [options]

Create a worktree for an issue ID (resolved under the configured worktree base
dir; default: ../.worktrees/<repo> beside the main checkout), optionally with an
explicit branch-name positional.

Bare 'create <ID>' is a new-work claim, not a discovery command. Every
new-branch mode, including --from, checks the normalized issue branch, an
explicit requested branch, and BOT_NAME/<issue> across worktrees, local/remote
refs, and open PRs. Existing ownership exits 75 and leaves local branches
unchanged — inspect or monitor owned work instead of spawning a second
implementer.
  - Origin remote-head or GitHub PR discovery failure exits 1 before any
    worktree config, branch, or target-path mutation; never interpret an
    outage as absence.
  - Unreachable secondary remotes are skipped with a warning; reachable ones
    still count as ownership signals.
  - A repository-local claim lock holds the final repeated discovery through
    'git worktree add'.
  - Run issue creates as separate commands and check each result.
  - A fresh worktree is unclaimed: create never claims a session-guard lease.

Options:
  --base BRANCH   Checkout an existing remote branch into the worktree;
                  the default branch instead starts a new issue branch from it
                  (it is always checked out in the main checkout and is never
                  issue-ownership evidence)
  --from REF      Create a new branch (named after ID) starting from REF
                  (branch, tag, or commit) after the normal ownership claim
                  gate
  --pr NUMBER     Look up the branch from a GitHub PR number (implies --base);
                  with --base, the way to inspect existing remote work whose
                  issue worktree is absent. A fork PR checks out origin's
                  refs/pull/NUMBER/head as local branch fork-pr-NUMBER, with
                  no upstream
  --reuse         Explicitly reuse an existing issue worktree: refuses a
                  foreign session-guard lease by name (exit 75), refreshes its
                  own lease in place, rebases onto origin/<default>, then
                  refreshes setup. Requires the target's exact canonical path
                  to be registered to this repository's common Git directory;
                  incomplete directories are preserved and exit 75.
  --restack       When reusing, stop in the conflict state for resolution
                  instead of aborting the rebase
  --replay        With --reuse/--restack: run the same restack as an ordered
                  cherry-pick replay with no rebase porcelain, for execution
                  policies that reject 'git rebase'

Reuse rebase conflicts:
  Bare create never rebases an existing worktree. When the --reuse rebase
  conflicts, the run aborts it and exits 1 listing the conflicting files; the
  worktree is left clean on its pre-rebase state. Two recovery paths:
    1. Resolve in place: re-run 'create <ID> --restack'. The rebase re-runs
       and pauses in the conflict state. Resolve the listed files, stage each
       with 'git -C <path> add <file>', then 'worktree restack continue <ID>';
       repeat if it stops again. 'restack skip <ID>' drops a commit already
       represented by the new base; 'restack abort <ID>' restores the
       pre-restack branch.
    2. Discard divergence: 'remove <ID>' then 'create <ID>' recreates the
       worktree fresh from origin/<default>, losing the local commits that
       conflicted.
  With no conflict, --restack completes the same rebase as --reuse. The
  guarded actions fail closed on missing, stale, or unrelated state
  (restack --help).

Policy-blocked rebase (cherry-pick replay fallback):
  When an execution policy rejects top-level 'git rebase' porcelain, never
  retry the porcelain and never substitute a raw --force push. Add --replay
  to the guarded restack instead; the controls stay 'restack
  continue|skip|abort <ID>', and the tool refuses a dirty tree or a range
  containing a merge commit.

EOF
}

print_remove_help() {
  worktree_message help remove
  cat <<'EOF'
Usage: worktree remove [ID|/path]

Remove a worktree and delete its local branch when it is safely merged.
Accepts an issue ID (resolved under the configured worktree base dir, falling
back to the worktree registered for the issue branch) or a direct path.

Failure semantics:
  remove deletes the worktree before deleting the local branch. Configured
  symlinks are never pre-stripped; a refusal issued before deletion starts
  leaves the worktree, its symlinks, and its branch untouched, and Git's
  message is reported. A failure partway through can leave the worktree
  partially removed: treat a removal failure as "inspect what remains"
  (fix-links restores configured symlinks); the branch is never deleted on
  that path. remove checks for a native 'git worktree lock' up front and
  exits non-zero with a diagnostic naming the lock reason and the
  'git worktree unlock' command. The branch goes only on the proof cleanup
  uses: ancestry into the default branch, or, when a squash erased that, a
  pull request gh reports merged into the default branch of THIS repository
  whose head commit IS this branch's tip. 'git branch -d' is not that proof and is not consulted —
  it deletes a branch merged into its configured UPSTREAM, which 'push' sets,
  so it passes for any pushed branch however far it is from the default
  branch. Every other answer keeps the branch, and the exit is non-zero with a
  diagnostic naming the remaining branch, the answer the proof gave, and the
  manual 'git branch -D' recovery command.

Session leases:
  remove releases its own lease before removing. A foreign lease is left
  alone and refuses the removal, naming the owner.
EOF
}

print_cleanup_help() {
  worktree_message help cleanup
  cat <<'EOF'
Usage: worktree cleanup [--stale] [--ttl-minutes N]

Remove worktrees whose branch is already merged into origin/<default>.
A worktree held by a session guard lease is never collected — not even one
this session claimed — nor is a zero-commit worktree: a branch with no
commits of its own is pending work, not merged work. Every skip is reported;
a quiet cleanup means nothing was held back.

cleanup fetches origin, considers non-main registered worktrees, and proves
each branch merged two ways: ancestry into origin/<default> (or the local
default branch when the remote ref is unavailable), or, when ancestry fails,
a pull request gh reports merged into <default> in THIS repository whose
head commit IS this branch's tip. The second proof is what a squash merge needs — it rewrites the
work into a new commit, so a merged branch is an ancestor of nothing. With
merge proven, cleanup asks Git to remove the intact worktree and deletes the
local branch.

The proof is that commit, never the branch name. One name is reused by every
worktree an issue ever had, so a branch carrying commits past the pull request
that merged it is unmerged work: cleanup keeps it and says so. Anything short
of a proof keeps the worktree and names its reason, a lookup that cannot
answer included. If the worktree listing itself fails, cleanup exits nonzero
having inspected nothing, rather than reporting the empty sweep as a clean
one. If Git cannot remove a worktree, cleanup exits nonzero and preserves its
path, configured symlinks, and branch for manual recovery. If branch deletion
fails after worktree removal, cleanup also exits nonzero and names the
remaining branch.

Options:
  --stale             Also collect worktrees whose guard lease is past the TTL
                      (an abandoned session). Releases the lease, then removes.
  --ttl-minutes N     Staleness horizon for --stale (default: 720)
EOF
}

print_push_help() {
  worktree_message help push
  cat <<'EOF'
Usage: worktree push [ID|/path] [--set-upstream|-u] [--no-rebase]

Push worktree branch to remote. Auto-rebases onto origin/<default> first.
Uses BOT_REMOTE_NAME from project config if set, otherwise falls back to
origin.

Resolution: 'push ISSUE_ID' normally resolves through the configured worktree
registry. When run from a checkout whose current branch already matches the
normalized issue branch, it pushes that active checkout instead (app-created
worktrees).

Force-with-lease authorization: after the auto-rebase, the push uses a scoped
--force-with-lease pinned to the target branch OID known before the rebase.
'create --reuse' and the supported 'create --restack' conflict-recovery flow
persist the same narrowly scoped authorization in the worktree: it records
the exact observed remote OID and the exact successfully restacked local
head. push accepts that rewritten head or later commits built on it, still
pins the force-with-lease to the recorded remote OID, and consumes the
authorization after success. A different local rewrite, remote movement while
conflict resolution is pending, or a moved remote at push time fails closed.
Plain pushes are still used with --no-rebase.

rebase-map: when the auto-rebase rewrites branch commits, push prints one
'rebase-map: <old-sha> <new-sha>' line per rewritten commit on stdout
('dropped' in place of the new SHA when the replayed commit's patch was
already upstream) so callers can remap commit SHAs recorded before the rebase
(kendex#728). Commits pair by position when the pre/post counts match,
otherwise by commit subject. A push that skips the rebase, or one run with
--no-rebase, prints no map.

A refused push names its judge. A pre-push hook that publishes the
commit-guards message protocol ('pre-push: <key>=<value>' lines, a completed
run ending in 'pre-push: result=<code>') is reported as
'worktree-push-hook-rejected': the attempt updated no remote ref, and the
hook's own lines below the record name what to fix. Every other failure under
a force-with-lease is reported as 'worktree-push-rejected', and the rest as
'worktree-push-failed'.

GitHub auth: push and origin fetches use the GitHub skill's git-https-auth
behavior when available: if gh auth is valid, the git command gets a
temporary HTTPS rewrite and 'gh auth git-credential' config. Remote URLs and
git config are not modified. KENDEX_GITHUB_GIT_HTTPS_FALLBACK=never forces
the normal SSH path.

Options:
  -u, --set-upstream    Set upstream tracking branch
  --no-rebase           Skip auto-rebase

Any other flag is a usage error (exit 1), so a typo cannot quietly become a
default-behavior push. The ID or path may appear before or after the flags,
but only once, and it may not be empty: an empty target would fall back to
the current checkout and push something the caller never named.
EOF
}

print_fix_links_help() {
  worktree_message help fix-links
  cat <<'EOF'
Usage: worktree fix-links [ID|/path]
       worktree repair-links [ID|/path]

Restore configured symlinks, copies, and mkdirs in a worktree — the repair
after a manual rebase or merge that clobbered them, or after a
partially-completed remove. repair-links is the git-hook-driven variant that
never destroys untracked data and exits 0 quietly for the main checkout or an
unregistered path. Run fix-links FROM THE MAIN CHECKOUT: a worktree copy of
this script may itself be among the missing files.

Recovery routing — route by shape, not by whether 'test -L' passes:
  - An untracked-only WORKTREE_SYMLINKS entry must be a symlink. Missing, or
    a real directory instead: fix-links, from the main checkout.
  - An entry with tracked content underneath is a real directory BY DESIGN,
    holding the tracked files plus one symlink per untracked child, except
    an untracked .gitignore, which is a copy of main's file. A child
    missing its link, or itself a real path: fix-links (heals per child;
    never overwrites a child holding data git does not track — reported
    instead; the .gitignore copy is the one child it re-copies on drift).
  - A genuinely modified or corrupt TRACKED file: 'git checkout -- <path>',
    run in the checkout the file really lives in.
  'git checkout -- <entry>' is never the recovery for an untracked-only
  entry: the path holds no tracked content, so the command changes nothing
  while the link stays broken.

Exit status:
  fix-links judges the RESULT of its pass, not the repair's return codes:
  'Restored symlinks' and exit 0 only when every WORKTREE_SYMLINKS and
  WORKTREE_RELATIVE_SYMLINKS entry ended healthy — present, a symlink, and
  resolving to the target this command gives it. Anything else is named and
  the exit is non-zero: a materialized path left in place, an entry with
  no such path in the MAIN checkout (setup skips those outright), a link
  that never got created, or one pointing somewhere else. The errors that
  name fix-links as their remediation are re-triggered by exactly those
  paths, so claiming success for one loops the operator on a command that
  changed nothing.

Symlink entries that shadow tracked content:
  When a configured symlink path is a tracked FILE in the worktree branch,
  setup marks that file assume-unchanged before replacing it so 'git status'
  stays clean. Directory entries with tracked content are linked per child:
  setup does not link the parent — the entry stays a real directory, tracked
  paths stay real files git owns, and only the untracked children are
  symlinked, recursing into children that mix tracked and untracked content.
  A newly installed skill under the entry is linked on the next
  create/fix-links/auto-repair pass. One child is copied instead of linked:
  an untracked .gitignore, because git refuses to read .gitignore through
  a symlink ("unable to access ... Too many levels of symbolic links") and
  would apply none of its rules. The main checkout's file is the source:
  every pass re-copies it when the content differs, so a change on main
  reaches the worktree on the next pass and an edit made to the worktree
  copy is overwritten. Every other untracked child goes through the
  same safety check as a top-level entry: a child that has materialized as a
  real file or directory holding data git does not track, or that differs
  from the index, is reported and left in place, never overwritten. A child
  nesting deeper than 8 levels is reported the same way. Either makes setup
  fail naming the affected paths — an error from create/fix-links, a blocked
  warning from hook-driven auto-repair.
  A worktree carrying the legacy layout — a parent link over tracked
  content, tracked files underneath marked assume-unchanged — heals on the
  next fix-links or hook repair: the parent link becomes a real directory,
  the bits are cleared, and missing tracked files are restored from the
  index (locally modified ones are never touched). create --reuse/--restack
  reconcile the same layout before rebasing, and re-apply setup on every
  terminal path: success, a rebase that never started, an aborted conflict,
  restack continue, and restack abort. A --restack paused on conflicts stays
  un-shadowed; the links return when the restack finishes or aborts.

info/exclude entries:
  The ignore entry setup writes for each symlinked path goes into the COMMON
  git dir's info/exclude, which every checkout reads. When the path holds
  tracked content, setup follows the entry with '!<path>/' (a trailing-slash
  pattern matches a real directory but NOT a symlink pointing at one).
  Runtime-only paths keep the plain entry. The shape is re-evaluated on every
  create/fix-links against both indexes, either one enough.

Git-hook auto-repair:
  create and fix-links install shared post-checkout, post-merge, and
  post-rewrite hooks into the MAIN checkout's hooks directory
  ('git rev-parse --git-path hooks'), which covers every worktree and every
  harness. The hook logic lives in an owned helper file,
  hooks/kendex-worktree-autorepair, rewritten on every install; the three
  stock hooks get one marked delegating line — an existing shell hook is
  appended to, never overwritten; a non-shell or non-executable (disabled)
  hook is left alone with a warning; the append is idempotent.
  core.hooksPath is never used or modified: when it is set, the install is
  skipped with a warning — add a repair-links call to those hooks manually.
  The helper no-ops in the main checkout and in repos without the skill
  installed, and never fails the git operation it runs after. Repair
  re-asserts the configured WORKTREE_SYMLINKS entries only, with one extra
  guarantee: a materialized path holding files git does not track (untracked
  OR ignored) is never clobbered; the hook warns loudly, names the files, and
  points at manual fix-links after the data has been moved or deleted.
EOF
}

print_repair_links_help() {
  worktree_message help repair-links "repair-links is the git-hook-driven variant of fix-links; the shared contract is under: worktree fix-links --help"
}

print_check_help() {
  worktree_message help check
  cat <<'EOF'
Usage: worktree check

Pre-create git state check of the MAIN checkout (JSON: uncommitted,
unpushed, unpushed_commits). Takes no arguments; it never inspects a
worktree, only the main checkout and its default branch.
EOF
}

print_list_help() {
  worktree_message help list
  cat <<'EOF'
Usage: worktree list

List every worktree registered to this repository (git worktree list), the
main checkout included.
EOF
}

print_path_exists_help() {
  worktree_message help path
  cat <<'EOF'
Usage: worktree path <ID>
       worktree exists <ID>

path prints the worktree path derived for an issue ID (the configured base
dir, falling back to the worktree registered for the issue branch). exists
prints "true" when a directory exists at that path, "false" otherwise; both
print to stdout and exit 0.
EOF
}

print_hooks_help() {
  worktree_message help hooks
  cat <<'EOF'
Usage: worktree codex-setup    [PATH]
       worktree codex-branch   <ISSUE> [PATH]
       worktree codex-cleanup  [PATH]
       worktree claude-setup   [PATH]
       worktree claude-cleanup [PATH]

App-created worktree hooks. The app (Codex Desktop, Claude Code) owns
worktree and branch creation and deletion; the setup hooks apply the same
project-local setup that create applies — env/config symlinks, configured
copies and dirs, optional bot git config and remote — inside a worktree git
has already created (default: the current directory). codex-branch
normalizes an app-managed branch name to the issue branch orch expects
before 'orch start'. The cleanup hooks are non-destructive and never remove
symlinks: mutating tracked symlink paths before the app has actually
removed the worktree can leave it dirty. Installation wiring: the worktree
skill's references/hooks.md.
EOF
}

# Every help form is answered here, before git resolution and before any
# project env file is read: a sourced .env.local statement must never run
# under --help, and help must work outside a repository. The scan covers every
# argv position — enumerating positions is how this class leaks.
case "${1:-}" in
  --help|-h|help) print_worktree_usage; exit 0 ;;
esac
_want_help=""
for _arg in "${@:2}"; do
  case "$_arg" in
    --help|-h) _want_help=1; break ;;
  esac
done
if [[ -n "$_want_help" ]]; then
  case "${1:-}" in
    restack)      print_restack_help; exit 0 ;;
    create)       print_create_help; exit 0 ;;
    remove)       print_remove_help; exit 0 ;;
    cleanup)      print_cleanup_help; exit 0 ;;
    check)        print_check_help; exit 0 ;;
    list)         print_list_help; exit 0 ;;
    path|exists)  print_path_exists_help; exit 0 ;;
    push)         print_push_help; exit 0 ;;
    fix-links)    print_fix_links_help; exit 0 ;;
    repair-links) print_repair_links_help; exit 0 ;;
    codex-setup|codex-branch|codex-cleanup|claude-setup|claude-cleanup)
                  print_hooks_help; exit 0 ;;
  esac
fi
unset _want_help _arg
