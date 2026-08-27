# shellcheck shell=bash
# Fixture writers for the gh shim (gh-shim.sh beside this file). Sourced by
# the selftest and the suites under tests/ after they set $fixtures (the
# shim's GH_SHIM_FIXTURES directory) and $HEAD (the sha under evaluation);
# it runs under the sourcing proof's own options and sets none of its own. Each
# writer produces exactly the shape the real endpoint returns, so a fixture
# never models a field the predicate would not see.

list_items() { # ';'-separated string -> one trimmed non-empty item per line
  printf '%s' "$1" | tr ';' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;/^$/d'
}
first_item() { list_items "$1" | head -n 1; }

comment() { # login, body
  jq -n --arg login "$1" --arg body "$2" '[{user:{login:$login},body:$body}]'
}
threads() { # isResolved values as args
  local nodes="[]"
  for r in "$@"; do nodes="$(jq -c --argjson r "$r" '. + [{isResolved:$r}]' <<<"$nodes")"; done
  jq -n --argjson nodes "$nodes" \
    '{data:{repository:{pullRequest:{reviewThreads:{pageInfo:{hasNextPage:false},nodes:$nodes}}}}}'
}
review() { # login, state, submitted_at, [commit sha; default HEAD], [body] -> one review row
  # Real review rows always carry a body (often ""), so the fixture does too:
  # the errored-attestation filter reads it, and modeling the field as absent
  # would leave the `.body // ""` fallback the only shape ever exercised.
  jq -n --arg sha "${4:-$HEAD}" --arg login "$1" --arg state "$2" --arg at "${3:-2026-01-01T00:00:00Z}" \
    --arg body "${5-}" \
    '{commit_id:$sha,state:$state,submitted_at:$at,body:$body,user:{login:$login}}'
}
reviews_set() { # rows... -> reviews.json
  local rows="[]" row
  for row in "$@"; do rows="$(jq -c --argjson r "$row" '. + [$r]' <<<"$rows")"; done
  printf '%s\n' "$rows" >"$fixtures/reviews.json"
}
checkrun() { # name, conclusion, summary, [app slug] -> checkruns.json
  # Real check runs always carry a publishing app; the default models a
  # trusted reviewer's own app. Pass "github-actions" for the near-miss:
  # a PR workflow can publish under ANY NAME through that shared app.
  # Every real row also carries a run id — the predicate validates it, so
  # the fixture models the real shape.
  jq -n --arg name "$1" --arg conclusion "$2" --arg summary "${3:-}" --arg app "${4:-trusted-reviewer-app}" \
    '{check_runs:[{id:1,name:$name,conclusion:$conclusion,app:{slug:$app},output:{title:null,summary:$summary}}]}' \
    >"$fixtures/checkruns.json"
}
compare_fix() { # status, [files JSON array] -> compare.json (the N...head delta)
  jq -n --arg status "$1" --argjson files "${2:-[]}" '{status:$status,files:$files}' \
    >"$fixtures/compare.json"
}
delta_file() { # filename, status, patch -> one compare files[] entry
  jq -n --arg fn "$1" --arg status "$2" --arg patch "$3" \
    '{filename:$fn,status:$status,patch:$patch}'
}
status_ctx() { # context, state, description, [creator login] -> statuses.json
  # The predicate reads the STATUSES LIST endpoint, which returns a bare
  # array and — unlike the combined endpoint — carries the real creator
  # login. The default models a normal publisher; pass "" explicitly for the
  # anomalous no-login case the reject-list must not trust. `${4-...}` and
  # NOT `${4:-...}`: the colon form would substitute the default for an
  # explicitly-empty argument, silently turning that case into its opposite.
  jq -n --arg ctx "$1" --arg state "$2" --arg desc "${3:-}" --arg creator "${4-trusted-publisher}" \
    '[{context:$ctx,state:$state,description:$desc,created_at:"2026-01-01T00:00:00Z",
      creator:(if $creator == "" then null else {login:$creator} end)}]' >"$fixtures/statuses.json"
}
