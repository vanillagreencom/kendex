# shellcheck shell=bash
#
# The disposable consumer the one-job suite runs a repository job in: a
# git repository with a bare origin, the minimal skill set linked from the
# source tree, the settings the job reads, the gh fake staged for what the
# job asks, and a private tmux server on the suite's own socket.
#
# Sourced by tests/job/one-job.sh, which supplies TMP_ROOT and REPO_ROOT.
# Every function refuses on its own first failure under the caller's errexit.

_ONE_JOB_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../github/tests/lib/gh-stub.sh
. "$_ONE_JOB_LIB_DIR/../../../github/tests/lib/gh-stub.sh"

# The skills the job executes, linked into the consumer's install. Nothing
# optional is linked: no review-gate, project-management, linear, harness-ci,
# second-opinion, commit-guards or preflight, so every optional read in the
# job takes its absence route.
ONE_JOB_SKILLS="orch agent-runtime change-scope dev reviewer worktree github mailbox decider"

# one_job_bin DIR — the sealed command directory: the gh fake, and the real
# tmux reachable only through this link, which dies with the scratch tree.
one_job_bin() { # DIR
  local real_tmux
  mkdir -p -- "$1"
  real_tmux="$(type -P tmux)" || return 1
  ln -s -- "$real_tmux" "$1/tmux"
  gh_stub_install "$1"
}

# one_job_server DIR SESSION — a private tmux server on DIR/tmux.sock with
# one detached session. Sets ONE_JOB_SOCKET and ONE_JOB_SERVER_PID; the suite
# ends it with `tmux -S $ONE_JOB_SOCKET kill-server` and nothing else.
one_job_server() { # DIR SESSION
  mkdir -p -- "$1"
  ONE_JOB_SOCKET="$1/tmux.sock"
  tmux -S "$ONE_JOB_SOCKET" new-session -d -s "$2" -x 200 -y 50 -c "$1" || return 1
  # The launch types its line into the window's shell. tmux opens that shell
  # through the user's login shell, whose profile rebuilds PATH and puts the
  # developer's own gh ahead of the fake; the suite's windows therefore pin
  # the sealed PATH the server was started with and run a bash that reads
  # no profile, so a lane sees exactly the commands the suite sealed.
  tmux -S "$ONE_JOB_SOCKET" set-option -g default-command "exec env PATH='$PATH' /bin/bash --noprofile --norc" || return 1
  ONE_JOB_SERVER_PID="$(tmux -S "$ONE_JOB_SOCKET" display-message -p '#{pid}')" || return 1
  export ONE_JOB_SOCKET ONE_JOB_SERVER_PID
}

# one_job_consumer ROOT STUB — the consumer checkout at ROOT/main on branch
# main, pushed to the bare ROOT/origin.git, with the job's settings committed
# and the skill links under .agents/skills. STUB is the harness executable
# AGENT_RUNTIME_HARNESS_BINARIES names as claude. Sets ONE_JOB_MAIN, ONE_JOB_ORIGIN
# and ONE_JOB_BASE, the base commit every job starts from.
one_job_consumer() { # ROOT STUB
  local root="$1" stub="$2" main skill
  main="$root/main"
  mkdir -p -- "$main/tests" "$main/tools" "$main/.agents/skills"
  git init -q -b main "$main"
  git -C "$main" config user.name Fixture
  git -C "$main" config user.email fixture@example.com
  git -C "$main" config commit.gpgsign false
  git -C "$main" config gc.auto 0
  git -C "$main" config maintenance.auto false
  for skill in $ONE_JOB_SKILLS; do
    ln -s -- "$REPO_ROOT/skills/$skill" "$main/.agents/skills/$skill"
  done
  printf 'tmp/\n.agents/\n.env.local\n' > "$main/.gitignore"
  # The render inventory a kendex install writes. The classifier reads the
  # base's inventory before it measures a diff; a base holding none is
  # standard by rule, whatever the diff's size.
  printf '[]\n' > "$main/.kendex-generated.json"
  cat > "$main/lib.sh" <<'SH'
# The consumer's library under test.
greet() { printf 'hello\n'; }
SH
  cat > "$main/tests/greet.test.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
. "$(dirname -- "$0")/../lib.sh"
[ "$(greet)" = hello ]
SH
  # The consumer's validation entry point. Before it runs the tests it waits,
  # bounded, for the orchestrator's record that this validation run was
  # admitted for the round: a validate stage in the item's workflow state.
  # The entry point is the one vantage that can observe whether admission
  # stood when validation ran, so the wait is the barrier that proves the
  # order instead of a clock comparison. The second run the publication
  # makes over the prepared head finds the round's closed stage.
  cat > "$main/tools/validate" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
common="$(git rev-parse --path-format=absolute --git-common-dir)"
item="$(git branch --show-current)"
state="${common%/.git}/tmp/workflow-state-$item.json"
tries=0
until [ -f "$state" ] && jq -e '[.stages[]? | select(.kind == "validate")] | length > 0' "$state" >/dev/null 2>&1; do
  tries=$((tries + 1))
  if [ "$tries" -ge 200 ]; then
    printf 'validate: admission-missing state=%s\n' "$state" >&2
    exit 1
  fi
  sleep 0.05
done
for t in tests/*.test.sh; do
  bash "$t"
done
printf 'validate: selection=all lanes=tests\n'
SH
  chmod +x "$main/tools/validate"
  # A commit hook, so the publication's "normal commit hooks" have one to run
  # and the micro route has an armed chain to confirm.
  cat > "$main/.git/hooks/pre-commit" <<'SH'
#!/usr/bin/env bash
mkdir -p tmp && printf 'hook\n' >> tmp/hook-count
SH
  chmod +x "$main/.git/hooks/pre-commit"
  cat > "$main/kendex.settings.toml" <<TOML
[env]
WORKTREE_DEFAULT_BRANCH = "main"
WORKTREE_BASE_DIR = "../trees"
WORKTREE_SYMLINKS = ".agents"
ORCH_DELIVERY = "push-base"
ORCH_PR_ORDER = "review-first"
DEV_VALIDATE_CMD = "bash tools/validate"
DEV_VALIDATE_TIMEOUT_SECS = "120"
AGENT_RUNTIME_TMUX_SESSION = "fleet"
AGENT_RUNTIME_TMUX_VERIFY_SECS = "20"
AGENT_RUNTIME_HARNESS_BINARIES = "claude=$stub"
TOML
  git -C "$main" add .
  git -C "$main" commit -qm 'chore: consumer base'
  git init -q --bare "$root/origin.git"
  git --git-dir="$root/origin.git" config gc.auto 0
  git --git-dir="$root/origin.git" config maintenance.auto false
  git -C "$main" remote add origin "$root/origin.git"
  git -C "$main" push -qu origin main
  ONE_JOB_MAIN="$main"
  ONE_JOB_ORIGIN="$root/origin.git"
  ONE_JOB_BASE="$(git -C "$main" rev-parse HEAD)"
}

# one_job_issue_body NUMBER DELTA — the GitHub issue body the job's admission
# reads: a Location line and an Expected delta, which item-tier judges.
one_job_issue_body() { # NUMBER DELTA
  printf '## Done-when\n\n- [ ] greet answers for a name\n\n## Filing record\n\n**Location**: `lib.sh`\n**Expected delta**: %s lines\n' "$2"
}

# one_job_stage_gh NUMBER BODY_FILE — the tracker's gh answers for issue
# NUMBER, staged before the lane launches. The verification's reads are the
# suite's own table (one-job.sh VERIFY_READS), staged after these.
one_job_stage_gh() { # NUMBER BODY_FILE
  local body
  body="$(cat -- "$2")"
  gh_stub_answer 'pr-list' ''
  # The admission's open pull requests of the repository, the
  # REST list the runtime pages: none.
  gh_stub_answer 'api-repos/owner/repo/pulls?state=open&per_page=100&page=1' '[]'
  gh_stub_answer "issue-view:number,title,body,url,labels,state" \
    "$(jq -cn --argjson n "$1" --arg body "$body" \
      '{number: $n, title: "Greet by name", body: $body, url: ("https://github.com/owner/repo/issues/" + ($n | tostring)), labels: [], state: "OPEN"}')"
  gh_stub_answer "issue-view:--jq .labels[].name" ''
  gh_stub_answer "issue-view:--jq .body" "$body"
  gh_stub_answer "issue-view:--json body" "$(jq -cn --arg body "$body" '{body: $body}')"
  gh_stub_answer 'issue-close' ''
}
