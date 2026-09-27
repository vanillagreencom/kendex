#!/usr/bin/env bash
# Runs in the catalog's trusted default-branch workflow. The installation
# token lists its own repositories; no local project list selects consumers.
set -euo pipefail
if ! repositories="$(gh api --paginate installation/repositories --jq '.repositories[] | select(.archived == false) | .full_name')"; then
  printf 'refresh-error=installation-read value=failed\n' >&2
  exit 1
fi
[ -n "$repositories" ] || { printf 'refresh-error=installation-empty value=0\n' >&2; exit 1; }
failed=0
while IFS= read -r repository; do
  # D007 gives the source catalog its own build-bound lock writer.
  if [ "$repository" = vanillagreencom/kendex ]; then
    printf 'refresh-excluded=%s\n' "$repository"
    continue
  fi
  if gh api --method POST "repos/$repository/dispatches" -f event_type=kendex-refresh; then
    printf 'refresh-dispatched=%s\n' "$repository"
  else
    printf 'refresh-error=dispatch value=%s\n' "$repository" >&2
    failed=1
  fi
done <<<"$repositories"
exit "$failed"
