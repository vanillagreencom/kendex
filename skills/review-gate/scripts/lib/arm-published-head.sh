# shellcheck shell=bash
# GitHub can show the previous pull-request head after a successful push.
# Sets RG_ARM_SEEN and RG_ARM_RESULT (matched or unmatched). A matched result
# means the arm was attempted; its exit status still decides whether it worked.
rg_arm_published_head() { # REPOSITORY NUMBER REVISION METHOD
  local repository="$1" number="$2" revision="$3" method="$4" reads=1
  RG_ARM_SEEN=""
  RG_ARM_RESULT=unmatched
  while :; do
    if ! RG_ARM_SEEN="$(gh pr view "$number" --repo "$repository" --json headRefOid --jq .headRefOid)" ||
        [ -z "$RG_ARM_SEEN" ] || [ "$RG_ARM_SEEN" = null ]; then
      printf 'pr-arm-error=head-read pr=%s pushed=%s\n' "$number" "$revision" >&2
      return 1
    fi
    if [ "$RG_ARM_SEEN" = "$revision" ]; then
      RG_ARM_RESULT=matched
      gh pr merge "$number" --repo "$repository" --auto "--$method" --match-head-commit "$revision"
      return $?
    fi
    [ "$reads" -lt 5 ] || return 0
    reads=$((reads + 1))
    sleep 2 || return $?
  done
}
