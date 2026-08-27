#!/usr/bin/env bash
# Everything the classifier cannot prove answers false, and answers it with a
# clean exit so the caller's step stays green while every lane runs.
set -euo pipefail
# shellcheck source=lib/sandbox.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/sandbox.sh"

repo="$(new_repo fail-closed)"
commit_paths "$repo" "baseline" README.md
base="$(git -C "$repo" rev-parse HEAD)"
commit_paths "$repo" "render only" .agents/skills/orch/SKILL.md
head="$(git -C "$repo" rev-parse HEAD)"

# The control: these endpoints classify true, so every case below fails closed
# on its own defect rather than on a diff that was never harness-only.
assert_verdict "the control endpoints classify true" true \
  --repo "$repo" --event push --base "$base" --head "$head"

closed() { # LABEL ARGS...
  local label="$1" out status
  shift
  set +e
  out="$("$HARNESS_ONLY" "$@" 2>/dev/null)"
  status=$?
  set -e
  assert_eq "$label" "harness_only=false exit 0" "$out exit $status"
}

closed "an unclassified event" \
  --repo "$repo" --event schedule --base "$base" --head "$head"
closed "workflow_dispatch is not a classified event" \
  --repo "$repo" --event workflow_dispatch --base "$base" --head "$head"
closed "no base endpoint" --repo "$repo" --event push --head "$head"
closed "an empty base endpoint" \
  --repo "$repo" --event push --base "" --head "$head"
closed "the all-zero base a first push sends" \
  --repo "$repo" --event push \
  --base 0000000000000000000000000000000000000000 --head "$head"
closed "a base that names no object" \
  --repo "$repo" --event push --base 1234567890123456789012345678901234567890 --head "$head"
closed "a head that names no object" \
  --repo "$repo" --event pull_request --base "$base" --head 1234567890123456789012345678901234567890
closed "a base that is not a commit" \
  --repo "$repo" --event push --base "$(git -C "$repo" rev-parse "HEAD^{tree}")" --head "$head"
closed "an empty diff between identical endpoints" \
  --repo "$repo" --event push --base "$head" --head "$head"
closed "a --repo that is not a checkout" \
  --repo "$SANDBOX" --event push --base "$base" --head "$head"
closed "a --repo that does not exist" \
  --repo "$SANDBOX/absent" --event push --base "$base" --head "$head"

# A repository with no commits at all: HEAD resolves to nothing.
empty="$(new_repo empty)"
closed "a checkout with no commits" --repo "$empty" --event push --base HEAD

# The reason reaches stderr, where the job log shows it.
reason="$("$HARNESS_ONLY" --repo "$repo" --event schedule --base "$base" 2>&1 >/dev/null)"
case "$reason" in
  *"event 'schedule'"*"running every lane"*)
    assert_eq "the reason names the event and the consequence" pass pass ;;
  *) assert_eq "the reason names the event and the consequence" pass "$reason" ;;
esac

report fail-closed
