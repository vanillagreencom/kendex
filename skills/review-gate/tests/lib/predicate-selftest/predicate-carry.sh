# shellcheck shell=bash
# Carry extends ancestor review evidence only across the enabled delta classes.
DOCS_DELTA="$(delta_file "README.md" modified '@@ -1 +1 @@
-old prose
+new prose')"
CODE_DELTA="$(delta_file "src/thing.sh" modified '@@ -1 +1 @@
-do_the_thing
+do_the_other_thing')"
COMMENT_DELTA="$(delta_file "src/thing.sh" modified '@@ -1,2 +1,2 @@
-# old comment
+# newer comment
   untouched_code_line')"
DOCS_DIR_CODE_DELTA="$(delta_file "docs/conf.py" modified '@@ -1 +1 @@
-extensions = []
+extensions = ["evil"]')"
AGENTS_DELTA="$(delta_file "AGENTS.md" modified '@@ -1 +1 @@
-old instruction
+new instruction')"
NESTED_AGENTS_DELTA="$(delta_file "skills/foo/AGENTS.md" modified '@@ -1 +1 @@
-old instruction
+new instruction')"
NEWLINE_NAME_DELTA="$(delta_file "$(printf 'skills/foo\nbar.md')" modified '@@ -1 +1 @@
-a
+b')"
RENDER_DELTA="$(delta_file ".agents/skills/hello/scripts/run.sh" modified '@@ -1 +1 @@
-do_the_thing
+do_the_other_thing')"
carry_row() { # NAME WANT EXIT CARRY EXCLUDE VENDORED RENDER MIN ERROR TRUST STATUS FILES PAGE2 FAULT THREAD REVIEWS
  jq -cn --arg name "$1" --arg want "$2" --arg exit "$3" --arg carry "$4" --arg exclude "$5" \
    --arg vendored "$6" --arg render "$7" --arg min "$8" --arg error "$9" --arg trust "${10}" \
    --arg status "${11}" --argjson files "${12}" --arg page2 "${13}" --arg fault "${14}" \
    --arg thread "${15}" --argjson reviews "${16}" \
    '{name:$name,want:$want,exit:$exit,carry:$carry,exclude:$exclude,vendored:$vendored,render:$render,min:$min,error:$error,trust:$trust,status:$status,files:$files,page2:$page2,fault:$fault,thread:$thread,reviews:$reviews}'
}
carry_rows="$(
  set -e
  carry_row "carry: docs-only delta from a reviewed ancestor carries" approved 0 "docs" "$ACTIVE_CARRY_EXCLUDE" "$ACTIVE_VENDORED_PATHS" "" "$ACTIVE_MIN_STATE" "$ACTIVE_ERROR_PATTERNS" "" "ahead" "[$DOCS_DELTA]" '' '' '' "$(jq -cn --argjson r "$(review reviewer APPROVED '2026-01-01T00:00:00Z' "$OTHER")" '[$r]')"
  carry_row "carry off (default): the same docs delta does NOT carry" awaiting 0 "" "$ACTIVE_CARRY_EXCLUDE" "$ACTIVE_VENDORED_PATHS" "" "$ACTIVE_MIN_STATE" "$ACTIVE_ERROR_PATTERNS" "" "ahead" "[$DOCS_DELTA]" '' '' '' "$(jq -cn --argjson r "$(review reviewer APPROVED '2026-01-01T00:00:00Z' "$OTHER")" '[$r]')"
  carry_row "carry: a code delta refuses (fresh evidence required)" awaiting 0 "docs" "$ACTIVE_CARRY_EXCLUDE" "$ACTIVE_VENDORED_PATHS" "" "$ACTIVE_MIN_STATE" "$ACTIVE_ERROR_PATTERNS" "" "ahead" "[$CODE_DELTA]" '' '' '' "$(jq -cn --argjson r "$(review reviewer APPROVED '2026-01-01T00:00:00Z' "$OTHER")" '[$r]')"
  carry_row "carry: one non-carry-safe file refuses the whole delta" awaiting 0 "docs" "$ACTIVE_CARRY_EXCLUDE" "$ACTIVE_VENDORED_PATHS" "" "$ACTIVE_MIN_STATE" "$ACTIVE_ERROR_PATTERNS" "" "ahead" "[$DOCS_DELTA,$CODE_DELTA]" '' '' '' "$(jq -cn --argjson r "$(review reviewer APPROVED '2026-01-01T00:00:00Z' "$OTHER")" '[$r]')"
  carry_row "carry: a code file under docs/ refuses (extension rule, not directory)" awaiting 0 "docs" "$ACTIVE_CARRY_EXCLUDE" "$ACTIVE_VENDORED_PATHS" "" "$ACTIVE_MIN_STATE" "$ACTIVE_ERROR_PATTERNS" "" "ahead" "[$DOCS_DIR_CODE_DELTA]" '' '' '' "$(jq -cn --argjson r "$(review reviewer APPROVED '2026-01-01T00:00:00Z' "$OTHER")" '[$r]')"
  carry_row "carry: comment-only change to a code file carries under 'comments'" approved 0 "comments" "$ACTIVE_CARRY_EXCLUDE" "$ACTIVE_VENDORED_PATHS" "" "$ACTIVE_MIN_STATE" "$ACTIVE_ERROR_PATTERNS" "" "ahead" "[$COMMENT_DELTA]" '' '' '' "$(jq -cn --argjson r "$(review reviewer APPROVED '2026-01-01T00:00:00Z' "$OTHER")" '[$r]')"
  carry_row "carry: comment-only delta does NOT carry when only 'docs' is enabled" awaiting 0 "docs" "$ACTIVE_CARRY_EXCLUDE" "$ACTIVE_VENDORED_PATHS" "" "$ACTIVE_MIN_STATE" "$ACTIVE_ERROR_PATTERNS" "" "ahead" "[$COMMENT_DELTA]" '' '' '' "$(jq -cn --argjson r "$(review reviewer APPROVED '2026-01-01T00:00:00Z' "$OTHER")" '[$r]')"
  carry_row "carry: '|' separator — mixed docs+comment delta carries with both classes" approved 0 "docs|comments" "$ACTIVE_CARRY_EXCLUDE" "$ACTIVE_VENDORED_PATHS" "" "$ACTIVE_MIN_STATE" "$ACTIVE_ERROR_PATTERNS" "" "ahead" "[$DOCS_DELTA,$COMMENT_DELTA]" '' '' '' "$(jq -cn --argjson r "$(review reviewer APPROVED '2026-01-01T00:00:00Z' "$OTHER")" '[$r]')"
  carry_row "carry: unknown extension refuses even a comment-looking delta" awaiting 0 "comments" "$ACTIVE_CARRY_EXCLUDE" "$ACTIVE_VENDORED_PATHS" "" "$ACTIVE_MIN_STATE" "$ACTIVE_ERROR_PATTERNS" "" "ahead" "[$(delta_file "src/thing.unknownext" modified '@@ -1 +1 @@
-# a
+# b')]" '' '' '' "$(jq -cn --argjson r "$(review reviewer APPROVED '2026-01-01T00:00:00Z' "$OTHER")" '[$r]')"
  carry_row "carry: an ADDED file refuses under 'comments' (modified-only)" awaiting 0 "comments" "$ACTIVE_CARRY_EXCLUDE" "$ACTIVE_VENDORED_PATHS" "" "$ACTIVE_MIN_STATE" "$ACTIVE_ERROR_PATTERNS" "" "ahead" "[$(delta_file "src/new.sh" added '@@ -0,0 +1 @@
+# new file of comments')]" '' '' '' "$(jq -cn --argjson r "$(review reviewer APPROVED '2026-01-01T00:00:00Z' "$OTHER")" '[$r]')"
  carry_row "carry: a changed shebang line is an interpreter change, not a comment" awaiting 0 "comments" "$ACTIVE_CARRY_EXCLUDE" "$ACTIVE_VENDORED_PATHS" "" "$ACTIVE_MIN_STATE" "$ACTIVE_ERROR_PATTERNS" "" "ahead" "[$(delta_file "src/thing.sh" modified '@@ -1 +1 @@
-#!/usr/bin/env bash
+#!/usr/bin/env dash')]" '' '' '' "$(jq -cn --argjson r "$(review reviewer APPROVED '2026-01-01T00:00:00Z' "$OTHER")" '[$r]')"
  carry_row "carry: a code file RENAMED to a .md name refuses under 'docs'" awaiting 0 "docs" "$ACTIVE_CARRY_EXCLUDE" "$ACTIVE_VENDORED_PATHS" "" "$ACTIVE_MIN_STATE" "$ACTIVE_ERROR_PATTERNS" "" "ahead" "[$(jq -n '{filename:"notes.md",previous_filename:"src/thing.sh",status:"renamed",patch:"@@ -1 +1 @@\n-do_the_thing\n+do_the_thing"}')]" '' '' '' "$(jq -cn --argjson r "$(review reviewer APPROVED '2026-01-01T00:00:00Z' "$OTHER")" '[$r]')"
  carry_row "carry: a fileless later compare page (real pagination shape) still carries" approved 0 "docs" "$ACTIVE_CARRY_EXCLUDE" "$ACTIVE_VENDORED_PATHS" "" "$ACTIVE_MIN_STATE" "$ACTIVE_ERROR_PATTERNS" "" "ahead" "[$DOCS_DELTA]" "$(printf '{"commits": []}\n')" '' '' "$(jq -cn --argjson r "$(review reviewer APPROVED '2026-01-01T00:00:00Z' "$OTHER")" '[$r]')"
  carry_row "carry: a non-object later compare page is exit 2, never a partial classification" "" 2 "docs" "$ACTIVE_CARRY_EXCLUDE" "$ACTIVE_VENDORED_PATHS" "" "$ACTIVE_MIN_STATE" "$ACTIVE_ERROR_PATTERNS" "" "ahead" "[$DOCS_DELTA]" "$(printf '[]\n')" '' '' "$(jq -cn --argjson r "$(review reviewer APPROVED '2026-01-01T00:00:00Z' "$OTHER")" '[$r]')"
  carry_row "carry: a later-page files array is ignored, never merged (files ride page one only)" approved 0 "docs" "$ACTIVE_CARRY_EXCLUDE" "$ACTIVE_VENDORED_PATHS" "" "$ACTIVE_MIN_STATE" "$ACTIVE_ERROR_PATTERNS" "" "ahead" "[$DOCS_DELTA]" "$(jq -n '{status:"ahead",files:[{filename:"src/smuggled.sh",status:"modified",patch:"@@ -1 +1 @@\n-a\n+b"}]}')" '' '' "$(jq -cn --argjson r "$(review reviewer APPROVED '2026-01-01T00:00:00Z' "$OTHER")" '[$r]')"
  carry_row "carry: identical tree (rebase residue) carries once any class is enabled" approved 0 "docs" "$ACTIVE_CARRY_EXCLUDE" "$ACTIVE_VENDORED_PATHS" "" "$ACTIVE_MIN_STATE" "$ACTIVE_ERROR_PATTERNS" "" "identical" '[]' '' '' '' "$(jq -cn --argjson r "$(review reviewer APPROVED '2026-01-01T00:00:00Z' "$OTHER")" '[$r]')"
  carry_row "carry: ahead with zero changed files is an identical tree — carries" approved 0 "docs" "$ACTIVE_CARRY_EXCLUDE" "$ACTIVE_VENDORED_PATHS" "" "$ACTIVE_MIN_STATE" "$ACTIVE_ERROR_PATTERNS" "" "ahead" '[]' '' '' '' "$(jq -cn --argjson r "$(review reviewer APPROVED '2026-01-01T00:00:00Z' "$OTHER")" '[$r]')"
  carry_row "carry: a non-ancestor candidate (diverged) never carries" awaiting 0 "docs" "$ACTIVE_CARRY_EXCLUDE" "$ACTIVE_VENDORED_PATHS" "" "$ACTIVE_MIN_STATE" "$ACTIVE_ERROR_PATTERNS" "" "diverged" "[$DOCS_DELTA]" '' '' '' "$(jq -cn --argjson r "$(review reviewer APPROVED '2026-01-01T00:00:00Z' "$OTHER")" '[$r]')"
  carry_row "carry-exclude unset (default): policy markdown still carries as docs" approved 0 "docs" "" "$ACTIVE_VENDORED_PATHS" "" "$ACTIVE_MIN_STATE" "$ACTIVE_ERROR_PATTERNS" "" "ahead" "[$AGENTS_DELTA]" '' '' '' "$(jq -cn --argjson r "$(review reviewer APPROVED '2026-01-01T00:00:00Z' "$OTHER")" '[$r]')"
  carry_row "carry-exclude: an excluded path in the delta refuses the carry" awaiting 0 "docs" "*AGENTS.md" "$ACTIVE_VENDORED_PATHS" "" "$ACTIVE_MIN_STATE" "$ACTIVE_ERROR_PATTERNS" "" "ahead" "[$AGENTS_DELTA]" '' '' '' "$(jq -cn --argjson r "$(review reviewer APPROVED '2026-01-01T00:00:00Z' "$OTHER")" '[$r]')"
  carry_row "carry-exclude: '*' crosses '/' — a nested AGENTS.md is excluded too" awaiting 0 "docs" "*AGENTS.md" "$ACTIVE_VENDORED_PATHS" "" "$ACTIVE_MIN_STATE" "$ACTIVE_ERROR_PATTERNS" "" "ahead" "[$NESTED_AGENTS_DELTA]" '' '' '' "$(jq -cn --argjson r "$(review reviewer APPROVED '2026-01-01T00:00:00Z' "$OTHER")" '[$r]')"
  carry_row "carry-exclude: a non-matching docs delta still carries (surgical)" approved 0 "docs" "*AGENTS.md" "$ACTIVE_VENDORED_PATHS" "" "$ACTIVE_MIN_STATE" "$ACTIVE_ERROR_PATTERNS" "" "ahead" "[$DOCS_DELTA]" '' '' '' "$(jq -cn --argjson r "$(review reviewer APPROVED '2026-01-01T00:00:00Z' "$OTHER")" '[$r]')"
  carry_row "carry-exclude: one excluded file refuses the WHOLE delta (2nd glob, spaces trimmed)" awaiting 0 "docs" ".github/*; *AGENTS.md" "$ACTIVE_VENDORED_PATHS" "" "$ACTIVE_MIN_STATE" "$ACTIVE_ERROR_PATTERNS" "" "ahead" "[$DOCS_DELTA,$AGENTS_DELTA]" '' '' '' "$(jq -cn --argjson r "$(review reviewer APPROVED '2026-01-01T00:00:00Z' "$OTHER")" '[$r]')"
  carry_row "carry-exclude: a directory glob catches instruction files under .github/" awaiting 0 "docs" ".github/*" "$ACTIVE_VENDORED_PATHS" "" "$ACTIVE_MIN_STATE" "$ACTIVE_ERROR_PATTERNS" "" "ahead" "[$(delta_file ".github/copilot-instructions.md" modified '@@ -1 +1 @@
-a
+b')]" '' '' '' "$(jq -cn --argjson r "$(review reviewer APPROVED '2026-01-01T00:00:00Z' "$OTHER")" '[$r]')"
  carry_row "carry-exclude: identical tree still carries (no delta to exclude)" approved 0 "docs" "*AGENTS.md" "$ACTIVE_VENDORED_PATHS" "" "$ACTIVE_MIN_STATE" "$ACTIVE_ERROR_PATTERNS" "" "identical" '[]' '' '' '' "$(jq -cn --argjson r "$(review reviewer APPROVED '2026-01-01T00:00:00Z' "$OTHER")" '[$r]')"
  carry_row "carry-exclude: applies to the comments class too (literal path)" awaiting 0 "comments" "src/thing.sh" "$ACTIVE_VENDORED_PATHS" "" "$ACTIVE_MIN_STATE" "$ACTIVE_ERROR_PATTERNS" "" "ahead" "[$COMMENT_DELTA]" '' '' '' "$(jq -cn --argjson r "$(review reviewer APPROVED '2026-01-01T00:00:00Z' "$OTHER")" '[$r]')"
  carry_row "carry-exclude: a newline-embedding filename refuses (record boundaries unprovable)" awaiting 0 "docs" "skills/*.md" "$ACTIVE_VENDORED_PATHS" "" "$ACTIVE_MIN_STATE" "$ACTIVE_ERROR_PATTERNS" "" "ahead" "[$NEWLINE_NAME_DELTA]" '' '' '' "$(jq -cn --argjson r "$(review reviewer APPROVED '2026-01-01T00:00:00Z' "$OTHER")" '[$r]')"
  carry_row "carry-exclude: the control-character refusal is scoped to configured exclusions" approved 0 "docs" "" "$ACTIVE_VENDORED_PATHS" "" "$ACTIVE_MIN_STATE" "$ACTIVE_ERROR_PATTERNS" "" "ahead" "[$NEWLINE_NAME_DELTA]" '' '' '' "$(jq -cn --argjson r "$(review reviewer APPROVED '2026-01-01T00:00:00Z' "$OTHER")" '[$r]')"
  carry_row "carry never waives a standing changes-requested" changes-requested 0 "docs" "$ACTIVE_CARRY_EXCLUDE" "$ACTIVE_VENDORED_PATHS" "" "$ACTIVE_MIN_STATE" "$ACTIVE_ERROR_PATTERNS" "" "ahead" "[$DOCS_DELTA]" '' '' '' "$(jq -cn --args '$ARGS.positional | map(fromjson)' "$(review "reviewer" APPROVED "2026-01-01T00:00:00Z" "$OTHER")" \
            "$(review "objector" CHANGES_REQUESTED "2026-01-02T00:00:00Z" "$OTHER")")"
  carry_row "carry never waives an unresolved thread" threads-open 0 "docs" "$ACTIVE_CARRY_EXCLUDE" "$ACTIVE_VENDORED_PATHS" "" "$ACTIVE_MIN_STATE" "$ACTIVE_ERROR_PATTERNS" "" "ahead" "[$DOCS_DELTA]" '' '' 'false' "$(jq -cn --argjson r "$(review reviewer APPROVED '2026-01-01T00:00:00Z' "$OTHER")" '[$r]')"
  carry_row "carry: a DISMISSED ancestor review is not a carry candidate" awaiting 0 "docs" "$ACTIVE_CARRY_EXCLUDE" "$ACTIVE_VENDORED_PATHS" "" "$ACTIVE_MIN_STATE" "$ACTIVE_ERROR_PATTERNS" "" "none" '[]' '' '' '' "$(jq -cn --args '$ARGS.positional | map(fromjson)' "$(review "reviewer" DISMISSED "2026-01-01T00:00:00Z" "$OTHER")")"
  carry_row "carry: the author's own ancestor review is not a carry candidate" awaiting 0 "docs" "$ACTIVE_CARRY_EXCLUDE" "$ACTIVE_VENDORED_PATHS" "" "$ACTIVE_MIN_STATE" "$ACTIVE_ERROR_PATTERNS" "" "none" '[]' '' '' '' "$(jq -cn --args '$ARGS.positional | map(fromjson)' "$(review "$AUTHOR" APPROVED "2026-01-01T00:00:00Z" "$OTHER")")"
  carry_row "carry: min_state=approved refuses a COMMENTED-only ancestor candidate" awaiting 0 "docs" "$ACTIVE_CARRY_EXCLUDE" "$ACTIVE_VENDORED_PATHS" "" "approved" "$ACTIVE_ERROR_PATTERNS" "" "none" '[]' '' '' '' "$(jq -cn --args '$ARGS.positional | map(fromjson)' "$(review "reviewer" COMMENTED "2026-01-01T00:00:00Z" "$OTHER")")"
  carry_row "carry: an errored ancestor auto-review is not a carry candidate" awaiting 0 "docs" "$ACTIVE_CARRY_EXCLUDE" "$ACTIVE_VENDORED_PATHS" "" "$ACTIVE_MIN_STATE" "$ERRORED_MARK" "" "ahead" "[$DOCS_DELTA]" '' '' '' "$(jq -cn --args '$ARGS.positional | map(fromjson)' "$(review "auto-reviewer" COMMENTED "2026-01-01T00:00:00Z" "$OTHER" "$ERRORED_BODY")")"
  carry_row "carry: an ancestor review QUOTING a pattern in later text is a candidate" approved 0 "docs" "$ACTIVE_CARRY_EXCLUDE" "$ACTIVE_VENDORED_PATHS" "" "any" "$ERRORED_MARK" "" "ahead" "[$DOCS_DELTA]" '' '' '' "$(jq -cn --args '$ARGS.positional | map(fromjson)' "$(review "reviewer" COMMENTED "2026-01-01T00:00:00Z" "$OTHER" "$(printf 'Reviewed 2 of 2 changed files.\n\nThe doc edit quotes the marker "encountered an error and was unable to review" verbatim; the wording matches the shipped default.')")")"
  carry_row "carry: a failed compare read is exit 2, never a guessed carry" "" 2 "docs" "$ACTIVE_CARRY_EXCLUDE" "$ACTIVE_VENDORED_PATHS" "" "$ACTIVE_MIN_STATE" "$ACTIVE_ERROR_PATTERNS" "" "none" '[]' '' 'fail' '' "$(jq -cn --argjson r "$(review reviewer APPROVED '2026-01-01T00:00:00Z' "$OTHER")" '[$r]')"
  carry_row "carry: a zero-byte compare producer is exit 2" "" 2 "docs" "$ACTIVE_CARRY_EXCLUDE" "$ACTIVE_VENDORED_PATHS" "" "$ACTIVE_MIN_STATE" "$ACTIVE_ERROR_PATTERNS" "" "none" '[]' '' 'empty' '' "$(jq -cn --argjson r "$(review reviewer APPROVED '2026-01-01T00:00:00Z' "$OTHER")" '[$r]')"
  carry_row "carry: an ahead compare with NO files array is exit 2, never an identical-tree guess" "" 2 "docs" "$ACTIVE_CARRY_EXCLUDE" "$ACTIVE_VENDORED_PATHS" "" "$ACTIVE_MIN_STATE" "$ACTIVE_ERROR_PATTERNS" "" 'raw' "$(jq -n '{status:"ahead"}')" '' '' '' "$(jq -cn --argjson r "$(review reviewer APPROVED '2026-01-01T00:00:00Z' "$OTHER")" '[$r]')"
  carry_row "carry: a file list AT the 300-entry compare cap refuses (completeness unprovable)" awaiting 0 "docs" "$ACTIVE_CARRY_EXCLUDE" "$ACTIVE_VENDORED_PATHS" "" "$ACTIVE_MIN_STATE" "$ACTIVE_ERROR_PATTERNS" "" "ahead" "$(jq -n '[range(300) | {filename:("docs/f\(.).md"),status:"modified",patch:"@@ -1 +1 @@\n-a\n+b"}]')" '' '' '' "$(jq -cn --argjson r "$(review reviewer APPROVED '2026-01-01T00:00:00Z' "$OTHER")" '[$r]')"
  carry_row "carry: 299 docs-only files (below the cap) still carries" approved 0 "docs" "$ACTIVE_CARRY_EXCLUDE" "$ACTIVE_VENDORED_PATHS" "" "$ACTIVE_MIN_STATE" "$ACTIVE_ERROR_PATTERNS" "" "ahead" "$(jq -n '[range(299) | {filename:("docs/f\(.).md"),status:"modified",patch:"@@ -1 +1 @@\n-a\n+b"}]')" '' '' '' "$(jq -cn --argjson r "$(review reviewer APPROVED '2026-01-01T00:00:00Z' "$OTHER")" '[$r]')"
  carry_row "carry: an unknown carry class is a config error" "" 2 "everything" "$ACTIVE_CARRY_EXCLUDE" "$ACTIVE_VENDORED_PATHS" "" "$ACTIVE_MIN_STATE" "$ACTIVE_ERROR_PATTERNS" "$ACTIVE_TRUSTED_LOGINS" "none" '[]' '' '' '' '[]'
  carry_row "vendored: a render-tree code delta carries under the committed path set" approved 0 "vendored" "$ACTIVE_CARRY_EXCLUDE" ".agents/*" "" "$ACTIVE_MIN_STATE" "$ACTIVE_ERROR_PATTERNS" "" "ahead" "[$RENDER_DELTA]" '' '' '' "$(jq -cn --argjson r "$(review reviewer APPROVED '2026-01-01T00:00:00Z' "$OTHER")" '[$r]')"
  carry_row "vendored off: the same delta refuses — a path set alone enables nothing" awaiting 0 "docs" "$ACTIVE_CARRY_EXCLUDE" ".agents/*" "" "$ACTIVE_MIN_STATE" "$ACTIVE_ERROR_PATTERNS" "" "ahead" "[$RENDER_DELTA]" '' '' '' "$(jq -cn --argjson r "$(review reviewer APPROVED '2026-01-01T00:00:00Z' "$OTHER")" '[$r]')"
  carry_row "render lane: a diff wholly under the render set approves with no evidence" approved 0 "$ACTIVE_CARRY" "$ACTIVE_CARRY_EXCLUDE" "$ACTIVE_VENDORED_PATHS" ".agents/*" "$ACTIVE_MIN_STATE" "$ACTIVE_ERROR_PATTERNS" "$ACTIVE_TRUSTED_LOGINS" "ahead" "[$(delta_file ".agents/skills/hello/scripts/run.sh" modified "")]" '' '' '' '[]'
  carry_row "render lane: one file outside the set — the same diff awaits review" awaiting 0 "$ACTIVE_CARRY" "$ACTIVE_CARRY_EXCLUDE" "$ACTIVE_VENDORED_PATHS" ".agents/*" "$ACTIVE_MIN_STATE" "$ACTIVE_ERROR_PATTERNS" "$ACTIVE_TRUSTED_LOGINS" "ahead" "[$(delta_file ".agents/skills/hello/scripts/run.sh" modified ""),$(delta_file "src/main.rs" modified "")]" '' '' '' '[]'
)" || exit 1
while IFS= read -r row; do
  reset
  CFG_CARRY="$(jq -r .carry <<<"$row")" || exit 1
  CFG_CARRY_EXCLUDE="$(jq -r .exclude <<<"$row")" || exit 1
  CFG_VENDORED_PATHS="$(jq -r .vendored <<<"$row")" || exit 1
  CFG_RENDER_PATHS="$(jq -r .render <<<"$row")" || exit 1
  CFG_MIN_STATE="$(jq -r .min <<<"$row")" || exit 1
  CFG_ERROR_PATTERNS="$(jq -r .error <<<"$row")" || exit 1
  CFG_TRUSTED_LOGINS="$(jq -r .trust <<<"$row")" || exit 1
  jq .reviews <<<"$row" >"$fixtures/reviews.json" || exit 1
  status="$(jq -r .status <<<"$row")" || exit 1
  case "$status" in
    none) : ;;
    raw) jq .files <<<"$row" >"$fixtures/compare.json" || exit 1 ;;
    *) files="$(jq -c .files <<<"$row")" || exit 1; compare_fix "$status" "$files" ;;
  esac
  page2="$(jq -r .page2 <<<"$row")" || exit 1
  [ -z "$page2" ] || printf '%s\n' "$page2" >"$fixtures/compare.page2.json"
  fault="$(jq -r .fault <<<"$row")" || exit 1
  case "$fault" in fail) export GH_SHIM_FAIL=compare ;; empty) export GH_SHIM_EMPTY=compare ;; '') : ;; *) exit 1 ;; esac
  thread_state="$(jq -r .thread <<<"$row")" || exit 1
  if [ "$thread_state" = false ]; then CFG_THREADS=enforce; threads false >"$fixtures/graphql.json"; fi
  name="$(jq -r .name <<<"$row")" || exit 1
  want="$(jq -r .want <<<"$row")" || exit 1
  expected_exit="$(jq -r .exit <<<"$row")" || exit 1
  run "$name" "$want" "$expected_exit"
done <<<"$carry_rows"
