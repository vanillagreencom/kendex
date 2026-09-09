# shellcheck shell=bash
# Sourced by review-predicate-selftest.sh with its neutral fixture world.
# Multi-page pagination merges: the shim serves <name>.page2.json
# concatenated after page 1 under --paginate, so the `jq -s` page merges are
# driven with real multi-page shapes — evidence beyond page 1 must count and
# a standing CR beyond page 1 must still block.
reset
CFG_TRUSTED_LOGINS=""
jq -n --argjson r "$(review "reviewer" COMMENTED "2026-01-01T00:00:00Z" "$OTHER")" '[$r]' >"$fixtures/reviews.json"
jq -n --argjson r "$(review "reviewer" APPROVED "2026-01-02T00:00:00Z")" '[$r]' >"$fixtures/reviews.page2.json"
run "pagination: review evidence on page 2 counts (page merge)" approved

reset
CFG_TRUSTED_LOGINS=""
jq -n --argjson r "$(review "reviewer" APPROVED)" '[$r]' >"$fixtures/reviews.json"
jq -n --argjson r "$(review "objector" CHANGES_REQUESTED)" '[$r]' >"$fixtures/reviews.page2.json"
run "pagination: a standing CR on page 2 still fails closed" changes-requested

reset
CFG_REVIEWERS="mech-bot[bot]:Reviewed commit:"; CFG_FLOOR=7
comment "mech-bot[bot]" "no binding line on page 1" >"$fixtures/comments.json"
comment "mech-bot[bot]" "Reviewed commit: \`${HEAD:0:7}\`" >"$fixtures/comments.page2.json"
run "pagination: comment-form evidence on page 2 counts" approved

reset
CFG_CONTEXTS="mech-ctx"
status_ctx "unrelated-ctx" success "someone else's status"
jq -n '[{context:"mech-ctx",state:"success",description:"analysis complete",created_at:"2026-01-01T00:00:00Z",creator:{login:"trusted-publisher"}}]' >"$fixtures/statuses.page2.json"
run "pagination: trusted status on statuses page 2 counts" approved

reset
CFG_CONTEXTS="mech-ctx"
jq -n '{check_runs:[{id:1,name:"mech-ctx",conclusion:"success",app:{slug:"trusted-reviewer-app"},output:{title:null,summary:"analysis complete"}}]}' >"$fixtures/checkruns.page2.json"
run "pagination: trusted check-run on page 2 counts" approved
